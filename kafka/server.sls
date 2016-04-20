{% from "kafka/map.jinja" import kafka, meta with context %}
{% set source_url = salt['pillar.get']('kafka:source_url', meta.default_url) %}


{% set zk_servers = [] %}
# To allow for flexibility around zookeeper servers (read: multiple ZK clusters)
# we need to check grains & pillar then fallback to whatever comes back from
# the salt mines when we go looking for minions with the zookeeper role
{% with  %}
  {% set from_mine = salt['mine.get']('roles:zookeeper', 'network.ip_addrs', expr_form='grain').values() %}
# grains > pillar
  {% set p = salt['pillar.get']('zookeeper:servers') %}
  {% set from_grain = salt['grains.get']('zookeeper:servers', p) %}

  {% if from_grain is seqence %}
    {% do zk_servers.extend(from_grain) %}
  {% else %}
    {% do zk_servers.extend(from_mine.values()) %}
  {% endif %}
{% endwith %}

{% set config = salt['pillar.get']('kafka:config', default=kafka.config, merge=True) %}

include:
  - kafka

{% set work_dirs = [] %}
{% if config.log.dirs is not string and config.log.dirs is sequence %}
  {% do work_dirs.extend(config.log.dirs) %}
{% elif config.log.dir is string %}
  {% do work_dirs.append(config.log.dir) %}
{% endif %}

{% if work_dirs|length >= 1 %}
# create the log dirs for brokers
kafka|create-directories:
  file.directory:
    - user: {{ kafka.user }}
    - group: {{ kafka.user }}
    - mode: 755
    - order: 10
    - makedirs: True
    - names:
        {%- for i in work_dirs %}
        - {{ i }}
        {%- endfor %}
    - recurse:
        - user
        - group
    - require:
        - sls: kafka
{% endif %}

kafka|install-dist:
  file.directory:
    - names:
        - {{ kafka.prefix }}
        - {{ kafka.config_dir }}
    - user: root
    - group: root
    - mode: 775
    - order: 10
    - makedirs: True
    - recurse:
      - user
      - group
      
  cmd.run:
    - name: curl -L '{{ source_url }}' | tar xz
    - cwd: {{ kafka.prefix }}
    - unless: test -f {{ meta.real_home }}/config/server.properties
    - require:
        - sls: kafka
        - file: kafka|install-dist
          
  alternatives.install:
    - name: kafka-home-link
    - link: {{ meta.alt_name }}
    - path: {{ meta.real_home }}
    - priority: 30
    - require:
      - cmd: kafka|install-dist

{% with port =  salt['pillar.get']("zookeeper:config:port", 2181) %}

kafka|server-conf:
  file.managed:
    - name: {{ kafka.config_dir }}/server.properties
    - source: salt://kafka/files/server.properties
    - user: {{ kafka.user }}
    - group: {{ kafka.user }}
    - mode: 644
    - template: jinja
    - priority: 30
    - require:
      - cmd: kafka|install-dist
    - context:
        zk_list:
          {%- for i in zk_servers %}
          - {{ '%s:%d'|format(i|first, port)}}
          {%- endfor %}
{% endwith %}

kafka|log4j-conf:
  file.managed:
    - name: {{ kafka.config_dir }}/log4j.properties
    - source: salt://kafka/files/log4j.properties
    - user: {{ kafka.user }}
    - group: {{ kafka.user }}
    - mode: 644
    - template: jinja
    - priority: 30
    - context:
        log_dir: {{ kafka.data_dir }}
    - require:
      - cmd: kafka|install-dist

kafka|upstart-config:
  file.managed:
    - name: /etc/init/{{ kafka.service }}.conf
    - source: salt://kafka/files/kafka.init.conf
    - mode: 644
    - template: jinja
    - context:
        home: {{ meta.real_home }}
        confdir: {{ kafka.config_dir }}
        user: {{ kafka.user }}
        log_dir: {{ kafka.data_dir }}
        java_home: {{ salt['pillar.get']('java_home', '/usr/lib/java') }}
    - require:
      - file: kafka|server-conf

kafka|enabled-file:
  file.managed:
    - name: /etc/default/{{ kafka.service }}
    - mode: 644
    - user: root
    - group: root
    - contents: |
        ENABLE="yes"

kafka|service:
  service.running:
    - name: {{ kafka.service }}
    - enable: true
    - init_delay: 10
    - watch:
      - file: kafka|enabled-file
      - file: kafka|upstart-config
      - file: kafka|server-conf
