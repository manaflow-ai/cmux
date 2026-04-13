# cmux patches for the bundled Ghostty zsh integration.
#
# Keep nested SSH hops aligned with the active local TERM. Users who opt into
# a portable TERM such as xterm-256color should not be silently upgraded to
# xterm-ghostty on the first hop, because deeper non-integrated hops will then
# inherit a TERM that may not exist on downstream servers.

_cmux_patch_ghostty_ssh() {
  [[ "${GHOSTTY_SHELL_FEATURES:-}" == *ssh-* ]] || return 0

  ssh() {
    emulate -L zsh
    setopt local_options no_glob_subst

    local current_term ssh_term ssh_opts ssh_cpath_dir ssh_cpath ssh_rc
    current_term="${TERM:-xterm-256color}"
    ssh_term="xterm-256color"
    ssh_opts=()
    ssh_cpath_dir=""
    ssh_cpath=""
    ssh_rc=0

    # Configure environment variables for remote session.
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-env* ]]; then
      ssh_opts+=(-o "SetEnv COLORTERM=truecolor")
      ssh_opts+=(-o "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION")
    fi

    # Only try to install/use xterm-ghostty when the active local TERM already
    # uses it. For xterm-256color and other local TERM values, keep Ghostty's
    # documented SSH fallback behavior and normalize the remote side to
    # xterm-256color.
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-terminfo* && "$current_term" == "xterm-ghostty" ]]; then
      local ssh_user ssh_hostname ssh_target ssh_config_output ssh_config_status
      local -a ssh_bootstrap_args
      local ssh_arg ssh_bootstrap_option ssh_short_bundle ssh_short_char
      local -i ssh_bootstrap_can_run ssh_bootstrap_expect_value ssh_bootstrap_target_seen
      ssh_user=""
      ssh_hostname=""
      ssh_target=""
      ssh_bootstrap_args=()
      ssh_bootstrap_option=""
      ssh_bootstrap_can_run=1
      ssh_bootstrap_expect_value=0
      ssh_bootstrap_target_seen=0

      # Preserve connection-affecting ssh arguments for the bootstrap hop, but
      # drop any trailing remote command so the probe can run its own installer.
      for ssh_arg in "$@"; do
        if (( ssh_bootstrap_target_seen )); then
          break
        fi

        if (( ssh_bootstrap_expect_value )); then
          ssh_bootstrap_args+=("$ssh_arg")

          case "$ssh_bootstrap_option" in
            -O|-Q|-W) ssh_bootstrap_can_run=0 ;;
          esac

          ssh_bootstrap_expect_value=0
          ssh_bootstrap_option=""
          continue
        fi

        case "$ssh_arg" in
          --)
            ssh_bootstrap_args+=("$ssh_arg")
            ;;
          -G|-N|-V|-s)
            ssh_bootstrap_can_run=0
            ssh_bootstrap_args+=("$ssh_arg")
            ;;
          -O*|-Q*|-W*)
            ssh_bootstrap_can_run=0
            ssh_bootstrap_args+=("$ssh_arg")
            ;;
          -[BbCcDEeFIiJLlmOopQRSwW])
            ssh_bootstrap_args+=("$ssh_arg")
            ssh_bootstrap_expect_value=1
            ssh_bootstrap_option="$ssh_arg"
            ;;
          -[BbCcDEeFIiJLlmOopQRSwW]?*)
            ssh_bootstrap_args+=("$ssh_arg")
            ssh_short_bundle="${ssh_arg#-}"
            while [[ -n "$ssh_short_bundle" ]]; do
              ssh_short_char="${ssh_short_bundle[1]}"
              case "$ssh_short_char" in
                G|N|V|f|s|O|Q|W) ssh_bootstrap_can_run=0 ;;
              esac
              case "$ssh_short_char" in
                B|b|C|c|D|E|e|F|I|i|J|L|l|m|O|o|p|Q|R|S|w|W) break ;;
              esac
              ssh_short_bundle="${ssh_short_bundle[2,-1]}"
            done
            ;;
          -?*)
            ssh_bootstrap_args+=("$ssh_arg")
            case "${ssh_arg#-}" in
              *G*|*N*|*V*|*f*|*s*|*O*|*Q*|*W*) ssh_bootstrap_can_run=0 ;;
            esac
            ;;
          *)
            ssh_bootstrap_args+=("$ssh_arg")
            ssh_bootstrap_target_seen=1
            ;;
        esac
      done

      (( ssh_bootstrap_target_seen )) || ssh_bootstrap_can_run=0
      (( ssh_bootstrap_expect_value )) && ssh_bootstrap_can_run=0
      ssh_config_output=""
      ssh_config_status=1
      if (( ssh_bootstrap_can_run )); then
        ssh_config_output=$(command ssh -G "$@" 2>&1)
        ssh_config_status=$?
      fi

      if (( ssh_config_status == 0 )); then
        while IFS=' ' read -r ssh_key ssh_value; do
          case "$ssh_key" in
            user) ssh_user="$ssh_value" ;;
            hostname) ssh_hostname="$ssh_value" ;;
          esac
        done <<< "$ssh_config_output"
      fi

      if [[ -n "$ssh_hostname" ]]; then
        ssh_target="$ssh_hostname"
        [[ -n "$ssh_user" ]] && ssh_target="${ssh_user}@${ssh_hostname}"

        # Check if terminfo is already cached.
        if [[ -n "${GHOSTTY_BIN_DIR:-}" && -x "$GHOSTTY_BIN_DIR/ghostty" ]] &&
           "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$ssh_target" >/dev/null 2>&1; then
          ssh_term="xterm-ghostty"
        elif (( $+commands[infocmp] )); then
          local ssh_terminfo

          ssh_terminfo=$(infocmp -0 -x xterm-ghostty 2>/dev/null)

          if [[ -n "$ssh_terminfo" ]]; then
            print "Setting up xterm-ghostty terminfo on $ssh_hostname..." >&2

            ssh_cpath_dir=$(mktemp -d "/tmp/ghostty-ssh-${ssh_user:-$USER}.XXXXXX" 2>/dev/null)
            if [[ -z "$ssh_cpath_dir" ]]; then
              ssh_cpath_dir="/tmp/ghostty-ssh-${ssh_user:-$USER}.$$-${EPOCHSECONDS}-${RANDOM}"
              command mkdir -p -- "$ssh_cpath_dir" >/dev/null 2>&1 || ssh_cpath_dir=""
            fi

            if (( ssh_bootstrap_can_run )) && [[ -n "$ssh_cpath_dir" ]]; then
              ssh_cpath="$ssh_cpath_dir/socket"

              if builtin print -r "$ssh_terminfo" | command ssh "${ssh_opts[@]}" -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s "${ssh_bootstrap_args[@]}" '
                infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                command -v tic >/dev/null 2>&1 || exit 1
                mkdir -p ~/.terminfo 2>/dev/null && tic -x - 2>/dev/null && exit 0
                exit 1
              ' 2>/dev/null; then
                ssh_term="xterm-ghostty"
                ssh_opts+=(-o "ControlPath=$ssh_cpath")

                # Cache successful installation when the helper is available.
                if [[ -n "${GHOSTTY_BIN_DIR:-}" && -x "$GHOSTTY_BIN_DIR/ghostty" ]]; then
                  "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --add="$ssh_target" >/dev/null 2>&1 || true
                fi
              else
                print "Warning: Failed to install terminfo." >&2
              fi
            elif [[ -z "$ssh_cpath_dir" ]]; then
              print "Warning: Failed to create temporary ssh control directory." >&2
            fi
          else
            print "Warning: Could not generate terminfo data." >&2
          fi
        else
          print "Warning: infocmp not available; cannot install xterm-ghostty terminfo." >&2
        fi
      elif (( ssh_config_status != 0 )) && [[ -n "$ssh_config_output" ]]; then
        print "Warning: ssh -G failed; skipping xterm-ghostty terminfo bootstrap: ${ssh_config_output%%$'\n'*}" >&2
      elif (( ssh_bootstrap_can_run )) && (( ssh_config_status == 0 )) && [[ -n "$ssh_config_output" ]]; then
        print "Warning: ssh -G did not resolve a hostname; skipping xterm-ghostty terminfo bootstrap." >&2
      fi
    fi

    {
      TERM="$ssh_term" command ssh "${ssh_opts[@]}" "$@"
      ssh_rc=$?
    } always {
      if [[ -n "$ssh_cpath_dir" && "$ssh_cpath_dir" == /tmp/ghostty-ssh-* ]]; then
        command rm -rf -- "$ssh_cpath_dir" >/dev/null 2>&1 || true
      fi
    }

    return $ssh_rc
  }
}

_cmux_patch_ghostty_ssh_deferred_init() {
  (( $+functions[_ghostty_deferred_init] )) || return 0
  [[ "${functions[_ghostty_deferred_init]}" == *"_cmux_patch_ghostty_ssh"* ]] && return 0

  # Ghostty installs its ssh() wrapper during deferred init on the first prompt.
  # Reapply the cmux wrapper there so prompted interactive shells keep the patch.
  functions[_ghostty_deferred_init]+=$'
  _cmux_patch_ghostty_ssh'
}

# Prompted interactive shells get the wrapper during Ghostty's deferred init.
# zsh -i -c shells install the same wrapper from the cmux wrapper .zshrc after
# the user's startup files have completed.
_cmux_patch_ghostty_ssh_deferred_init
builtin unfunction _cmux_patch_ghostty_ssh_deferred_init 2>/dev/null
