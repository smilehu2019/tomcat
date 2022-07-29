{{
	include "from"
	;
	include "shared"
-}}
FROM {{ from }}

ENV CATALINA_HOME /usr/local/tomcat
ENV PATH $CATALINA_HOME/bin:$PATH
RUN mkdir -p "$CATALINA_HOME"
WORKDIR $CATALINA_HOME

# let "Tomcat Native" live somewhere isolated
ENV TOMCAT_NATIVE_LIBDIR $CATALINA_HOME/native-jni-lib
ENV LD_LIBRARY_PATH ${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$TOMCAT_NATIVE_LIBDIR

# see https://www.apache.org/dist/tomcat/tomcat-{{ major }}/KEYS
# see also "versions.sh" (https://github.com/docker-library/tomcat/blob/master/versions.sh)
ENV GPG_KEYS {{
	# docker run --rm buildpack-deps:bullseye-curl bash -c 'wget -qO- https://www.apache.org/dist/tomcat/tomcat-10/KEYS | gpg --batch --import &> /dev/null && gpg --batch --list-keys --with-fingerprint --with-colons' | awk -F: '$1 == "pub" && $2 == "-" { pub = 1 } pub && $1 == "fpr" { fpr = $10 } $1 == "sub" { pub = 0 } pub && fpr && $1 == "uid" && $2 == "-" { print "\t\t\t#", $10; print "\t\t\t\"" fpr "\","; pub = 0 } END { print "\t\t\t# trailing comma 👀\n\t\t\tempty" }'
	{
		"10": [
			# Mark E D Thomas <markt@apache.org>
			"A9C5DF4D22E99998D9875A5110C01C5A2F6059E7",
			# trailing comma 👀
			empty
		],
		"9": [
			# Mark E D Thomas <markt@apache.org>
			"DCFD35E0BF8CA7344752DE8B6FB21E8933C60243",
			# Mark E D Thomas <markt@apache.org>
			"A9C5DF4D22E99998D9875A5110C01C5A2F6059E7",
			# Remy Maucherat <remm@apache.org>
			"48F8E69F6390C9F25CFEDCD268248959359E722B",
			# trailing comma 👀
			empty
		],
		"8": [
			# Andy Armstrong <andy@tagish.com>
			"79F7026C690BAA50B92CD8B66A3AD3F4F22C4FED",
			# Jean-Frederic Clere (jfclere) <JFrederic.Clere@fujitsu-siemens.com>
			"05AB33110949707C93A279E3D3EFE6B686867BA6",
			# kevin seguin <seguin@apache.org>
			"A27677289986DB50844682F8ACB77FC2E86E29AC",
			# Henri Gomez <hgomez@users.sourceforge.net>
			"47309207D818FFD8DCD3F83F1931D684307A10A5",
			# Yoav Shapira <yoavs@apache.org>
			"07E48665A34DCAFAE522E5E6266191C37C037D42",
			# Mark E D Thomas <markt@apache.org>
			"DCFD35E0BF8CA7344752DE8B6FB21E8933C60243",
			# Mark E D Thomas <markt@apache.org>
			"A9C5DF4D22E99998D9875A5110C01C5A2F6059E7",
			# Rémy Maucherat <remm@apache.org>
			"541FBE7D8F78B25E055DDEE13C370389288584E7",
			# Yoav Shapira <yoavs@computer.org>
			"F3A04C595DB5B6A5F1ECA43E3B7BBB100D811BBE",
			# Tim Whittington (CODE SIGNING KEY) <timw@apache.org>
			"9BA44C2621385CB966EBA586F72C284D731FABEE",
			# Mladen Turk (Default signing key) <mturk@apache.org>
			"F7DA48BB64BCB84ECBA7EE6935CD23C10D498E23",
			# Konstantin Kolinko (CODE SIGNING KEY) <kkolinko@apache.org>
			"765908099ACF92702C7D949BFA0C35EA8AA299F1",
			# Christopher Schultz <chris@christopherschultz.net>
			"5C3C5F3E314C866292F359A8F3AD5C94A67F707E",
			# trailing comma 👀
			empty
		],
	} | .[major] // error("missing GPG keys")
	| sort
	| join(" ")
}}

ENV TOMCAT_MAJOR {{ major }}
ENV TOMCAT_VERSION {{ .version }}
ENV TOMCAT_SHA512 {{ .sha512 }}

{{ if java_variant == "jdk" then ( -}}
RUN set -eux; \
	\
{{ if is_apt then ( -}}
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		dirmngr \
		gnupg \
	; \
{{ ) else ( -}}
# http://yum.baseurl.org/wiki/YumDB.html
	if ! command -v yumdb > /dev/null; then \
		yum install -y --setopt=skip_missing_names_on_install=False yum-utils; \
		yumdb set reason dep yum-utils; \
	fi; \
# a helper function to "yum install" things, but only if they aren't installed (and to set their "reason" to "dep" so "yum autoremove" can purge them for us)
	_yum_install_temporary() { ( set -eu +x; \
		local pkg todo=''; \
		for pkg; do \
			if ! rpm --query "$pkg" > /dev/null 2>&1; then \
				todo="$todo $pkg"; \
			fi; \
		done; \
		if [ -n "$todo" ]; then \
			set -x; \
			yum install -y --setopt=skip_missing_names_on_install=False $todo; \
			yumdb set reason dep $todo; \
		fi; \
	) }; \
	_yum_install_temporary gzip tar; \
{{ ) end -}}
	\
	ddist() { \
		local f="$1"; shift; \
		local distFile="$1"; shift; \
		local mvnFile="${1:-}"; \
		local success=; \
		local distUrl=; \
		for distUrl in \
# https://issues.apache.org/jira/browse/INFRA-8753?focusedCommentId=14735394#comment-14735394
			"https://www.apache.org/dyn/closer.cgi?action=download&filename=$distFile" \
# if the version is outdated (or we're grabbing the .asc file), we might have to pull from the dist/archive :/
			"https://downloads.apache.org/$distFile" \
			"https://www-us.apache.org/dist/$distFile" \
			"https://www.apache.org/dist/$distFile" \
			"https://archive.apache.org/dist/$distFile" \
# if all else fails, let's try Maven (https://www.mail-archive.com/users@tomcat.apache.org/msg134940.html; https://mvnrepository.com/artifact/org.apache.tomcat/tomcat; https://repo1.maven.org/maven2/org/apache/tomcat/tomcat/)
			${mvnFile:+"https://repo1.maven.org/maven2/org/apache/tomcat/tomcat/$mvnFile"} \
		; do \
			if curl -fL -o "$f" "$distUrl" && [ -s "$f" ]; then \
				success=1; \
				break; \
			fi; \
		done; \
		[ -n "$success" ]; \
	}; \
	\
	ddist 'tomcat.tar.gz' "tomcat/tomcat-$TOMCAT_MAJOR/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz" "$TOMCAT_VERSION/tomcat-$TOMCAT_VERSION.tar.gz"; \
	echo "$TOMCAT_SHA512 *tomcat.tar.gz" | sha512sum --strict --check -; \
	ddist 'tomcat.tar.gz.asc' "tomcat/tomcat-$TOMCAT_MAJOR/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz.asc" "$TOMCAT_VERSION/tomcat-$TOMCAT_VERSION.tar.gz.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	for key in $GPG_KEYS; do \
		gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
	done; \
	gpg --batch --verify tomcat.tar.gz.asc tomcat.tar.gz; \
	tar -xf tomcat.tar.gz --strip-components=1; \
	rm bin/*.bat; \
	rm tomcat.tar.gz*; \
	command -v gpgconf && gpgconf --kill all || :; \
	rm -rf "$GNUPGHOME"; \
	\
# https://tomcat.apache.org/tomcat-9.0-doc/security-howto.html#Default_web_applications
	mv webapps webapps.dist; \
	mkdir webapps; \
# we don't delete them completely because they're frankly a pain to get back for users who do want them, and they're generally tiny (~7MB)
	\
	nativeBuildDir="$(mktemp -d)"; \
	tar -xf bin/tomcat-native.tar.gz -C "$nativeBuildDir" --strip-components=1; \
{{ if is_apt then ( -}}
	apt-get install -y --no-install-recommends \
		dpkg-dev \
		gcc \
		libapr1-dev \
		libssl-dev \
		make \
	; \
{{ ) else ( -}}
	_yum_install_temporary \
		apr-devel \
		gcc \
		make \
		openssl11-devel \
	; \
{{ ) end -}}
	( \
		export CATALINA_HOME="$PWD"; \
		cd "$nativeBuildDir/native"; \
{{ if is_apt then ( -}}
		gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
{{ ) else "" end -}}
		aprConfig="$(command -v apr-1-config)"; \
		./configure \
{{ if is_apt then ( -}}
			--build="$gnuArch" \
{{ ) else "" end -}}
			--libdir="$TOMCAT_NATIVE_LIBDIR" \
			--prefix="$CATALINA_HOME" \
			--with-apr="$aprConfig" \
			--with-java-home="$JAVA_HOME" \
{{ if is_native_ge_2 then "" else ( -}}
			--with-ssl \
{{ ) end -}}
		; \
		nproc="$(nproc)"; \
		make -j "$nproc"; \
		make install; \
	); \
	rm -rf "$nativeBuildDir"; \
	rm bin/tomcat-native.tar.gz; \
	\
{{ if is_apt then ( -}}
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
	find "$TOMCAT_NATIVE_LIBDIR" -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { print $(NF-1) }' \
		| xargs -rt readlink -e \
		| sort -u \
		| xargs -rt dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| tee "$TOMCAT_NATIVE_LIBDIR/.dependencies.txt" \
		| xargs -r apt-mark manual \
	; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*; \
{{ ) else ( -}}
# mark any explicit dependencies as manually installed
	find "$TOMCAT_NATIVE_LIBDIR" -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ && $(NF-1) != "=>" { print $(NF-1) }' \
		| xargs -rt readlink -e \
		| sort -u \
		| xargs -rt rpm --query --whatprovides \
		| sort -u \
		| tee "$TOMCAT_NATIVE_LIBDIR/.dependencies.txt" \
		| xargs -r yumdb set reason user \
	; \
	\
# clean up anything added temporarily and not later marked as necessary
	yum autoremove -y; \
	yum clean all; \
	rm -rf /var/cache/yum; \
{{ ) end -}}
	\
# sh removes env vars it doesn't support (ones with periods)
# https://github.com/docker-library/tomcat/issues/77
	find ./bin/ -name '*.sh' -exec sed -ri 's|^#!/bin/sh$|#!/usr/bin/env bash|' '{}' +; \
	\
# fix permissions (especially for running as non-root)
# https://github.com/docker-library/tomcat/issues/35
	chmod -R +rX .; \
	chmod 777 logs temp work; \
	\
# smoke test
	catalina.sh version
{{ ) else ( -}}
COPY --from=tomcat:{{ .version }}-jdk{{ java_version }}-{{ vendor_variant }} $CATALINA_HOME $CATALINA_HOME
RUN set -eux; \
{{ if is_apt then ( -}}
	apt-get update; \
	xargs -rt apt-get install -y --no-install-recommends < "$TOMCAT_NATIVE_LIBDIR/.dependencies.txt"; \
	rm -rf /var/lib/apt/lists/*
{{ ) else ( -}}
	xargs -rt yum install -y --setopt=skip_missing_names_on_install=False < "$TOMCAT_NATIVE_LIBDIR/.dependencies.txt"; \
	yum clean all; \
	rm -rf /var/cache/yum
{{ ) end -}}
{{ ) end -}}

# verify Tomcat Native is working properly
RUN set -eux; \
	nativeLines="$(catalina.sh configtest 2>&1)"; \
	nativeLines="$(echo "$nativeLines" | grep 'Apache Tomcat Native')"; \
	nativeLines="$(echo "$nativeLines" | sort -u)"; \
	if ! echo "$nativeLines" | grep -E 'INFO: Loaded( APR based)? Apache Tomcat Native library' >&2; then \
		echo >&2 "$nativeLines"; \
		exit 1; \
	fi

EXPOSE 8080
CMD ["catalina.sh", "run"]
