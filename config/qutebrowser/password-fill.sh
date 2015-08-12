#!/bin/bash -e
#

set -o pipefail
shopt -s nocasematch

help() {
    blink=$'\e[1;31m'
    reset=$'\e[0m'
cat <<EOF
This script can only be used as a userscript for qutebrowser
2015, Thorsten Wißmann <edu _at_ thorsten-wissmann _dot_ de>

  $blink!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!$reset
  WARNING: the passwords are stored in qutebrowser's
           debug log reachable via the url qute:log
  $blink!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!$reset

Usage: run as a userscript form qutebrowser, e.g.:
  spawn --userscript /home/thorsten/.config/qutebrowser/password-fill.sh

Behaviour:
  It will try to find a username/password entry in the configured backend
  (currently only pass) for the current website and will load that pair of
  username and password to any form on the current page that has some password
  entry field.

EOF
}

if [ -z "$QUTE_FIFO" ] ; then
    help
    exit
fi

error() {
    local msg="$*"
    echo "message-error '${msg//\'/\\\'}'" >> "$QUTE_FIFO"
}
die() {
    error "$*"
    exit 0
}

simple_url="${QUTE_URL##*://}" # remove protocoll specification
simple_url="${simple_url%%\?*}" # remove GET parameters
simple_url="${simple_url%%/*}" # remove directory path
simple_url="${simple_url##www.}" # remove www. subdomain


reset_backend() {
    init() { true ; }
    query_entries() { true ; }
    open_entry() { true ; }
}

# =======================================================
# backend: PASS

# configuration options:
match_filename=1 # whether allowing entry match by filepath
match_line=1     # whether allowing entry match by URL-Pattern in file
match_line_pattern='^url: .*' # applied using grep -iE
user_pattern='^(user|username): '

GPG_OPTS=( "--quiet" "--yes" "--compress-algo=none" "--no-encrypt-to" )
GPG="gpg"
export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null)}"
which gpg2 &>/dev/null && GPG="gpg2"
[[ -n $GPG_AGENT_INFO || $GPG == "gpg2" ]] && GPG_OPTS+=( "--batch" "--use-agent" )

pass_backend() {
    init() {
        PREFIX="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
        if ! [ -d "$PREFIX" ] ; then
            die "Can not open password store dir »$PREFIX«"
        fi
    }
    query_entries() {
        local url="$1"

        if ((match_line)) ; then
            # add entries with matching URL-tag
            while read -r -d "" passfile ; do
                if $GPG "${GPG_OPTS}" -d "$passfile" \
                     | grep --max-count=1 -iE "${match_line_pattern}${url}" > /dev/null
                then
                    passfile="${passfile#$PREFIX}"
                    passfile="${passfile#/}"
                    files+=( "${passfile%.gpg}" )
                fi
            done < <(find -L "$PREFIX" -iname '*.gpg' -print0)
        fi
        if ((match_filename)) ; then
            # add entries wth matching filepath
            while read -r passfile ; do
                passfile="${passfile#$PREFIX}"
                passfile="${passfile#/}"
                files+=( "${passfile%.gpg}" )
            done < <(find -L "$PREFIX" -iname '*.gpg' | grep "$url")
        fi
    }
    open_entry() {
        local path="$PREFIX/${1}.gpg"
        password=""
        local firstline=1
        while read -r line ; do
            if ((firstline)) ; then
                password="$line"
                firstline=0
            else
                if [[ $line =~ $user_pattern ]] ; then
                    # remove the matching prefix "user: " from the beginning of the line
                    username=${line#${BASH_REMATCH[0]}}
                    break
                fi
            fi
        done < <($GPG "${GPG_OPTS}" -d "$path" )
    }
}
# =======================================================



reset_backend
pass_backend
init

query_entries "$simple_url"
file=$(printf "%s\n" "${files[@]}" | sort | uniq | sort -R | head -n 1)
if [ -z "$file" ] ; then
    die "No entry found for »$simple_url«"
fi
open_entry "$file"
#username="$(date)"
#password="XYZ"

[ -n "$username" ] || die "Username not set in entry $file"
[ -n "$password" ] || die "Password not set in entry $file"

js() {
cat <<EOF
    function hasPasswordField(form) {
        var inputs = form.getElementsByTagName("input");
        for (var j = 0; j < inputs.length; j++) {
            var input = inputs[j];
            if (input.type == "password") {
                return true;
            }
        }
        return false;
    };
    function loadData2Form (form) {
        var inputs = form.getElementsByTagName("input");
        for (var j = 0; j < inputs.length; j++) {
            var input = inputs[j];
            if (input.type == "text" || input.type == "email") {
                input.value = "$username";
            }
            if (input.type == "password") {
                input.value = "$password";
            }
        }
    };

    var forms = document.getElementsByTagName("form");
    for (i = 0; i < forms.length; i++) {
        if (hasPasswordField(forms[i])) {
            loadData2Form(forms[i]);
        }
    }
EOF
}

printjs() {
    js | sed 's,//.*$,,' | tr '\n' ' '
}
echo "jseval -q $(printjs)" >> "$QUTE_FIFO"