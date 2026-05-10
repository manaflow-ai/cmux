import Foundation

enum RemoteShellEnvironment {
    static func utf8LocaleSetupLines() -> [String] {
        [
            "case \"${LC_ALL:-${LC_CTYPE:-${LANG:-}}}\" in",
            "  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;",
            "  *) export LANG='C.UTF-8'; export LC_CTYPE='C.UTF-8'; export LC_ALL='C.UTF-8' ;;",
            "esac",
        ]
    }
}

enum RemoteShellIntegrationSnippet {
    static func script() -> String {
        """
        # cmux remote shell integration: emits OSC 7 cwd + branch hints for ssh/mosh panes.
        __cmux_remote_uri_escape() {
          local value="$1"
          value="${value//%/%25}"
          value="${value// /%20}"
          value="${value//#/%23}"
          value="${value//\\?/%3F}"
          value="${value//&/%26}"
          value="${value//=/%3D}"
          value="${value//+/%2B}"
          value="${value//\\//%2F}"
          value="${value//@/%40}"
          value="${value//[/%5B}"
          value="${value//]/%5D}"
          printf '%s' "$value"
        }

        __cmux_remote_path_escape() {
          local value="$1"
          value="${value//%/%25}"
          value="${value// /%20}"
          value="${value//#/%23}"
          value="${value//\\?/%3F}"
          value="${value//\\\\/%5C}"
          value="${value//[/%5B}"
          value="${value//]/%5D}"
          printf '%s' "$value"
        }

        __cmux_strip_control_chars() {
          LC_ALL=C tr -d '[:cntrl:]'
        }

        __cmux_remote_hostname() {
          if [ -n "${CMUX_REMOTE_HOST:-}" ]; then
            printf '%s' "$CMUX_REMOTE_HOST"
            return
          fi
          hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'remote'
        }

        __cmux_remote_git_branch_query() {
          [ "${CMUX_REMOTE_DISABLE_GIT:-}" = "1" ] && return 0
          command git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
          local branch dirty
          branch="$(command git symbolic-ref --quiet --short HEAD 2>/dev/null || command git rev-parse --short HEAD 2>/dev/null)" || return 0
          branch="$(printf '%s' "$branch" | __cmux_strip_control_chars)"
          [ -n "$branch" ] || return 0
          dirty=0
          if [ -n "$(command git status --porcelain --untracked-files=normal 2>/dev/null)" ]; then
            dirty=1
          fi
          printf '?cmux_git_branch=%s&cmux_git_dirty=%s' "$(__cmux_remote_uri_escape "$branch")" "$dirty"
        }

        __cmux_remote_report_prompt() {
          local host path query
          host="$(__cmux_remote_hostname | __cmux_strip_control_chars)"
          [ -n "$host" ] || host=remote
          host="$(__cmux_remote_uri_escape "$host")"
          path="$(__cmux_remote_path_escape "$(printf '%s' "${PWD:-/}" | __cmux_strip_control_chars)")"
          query="$(__cmux_remote_git_branch_query)"
          printf '\\033]7;file://%s%s%s\\033\\\\' "$host" "$path" "$query"
        }

        __cmux_remote_add_zsh_precmd_fallback() {
          case " ${precmd_functions[*]-} " in
            *" __cmux_remote_report_prompt "*) ;;
            *) precmd_functions+=(__cmux_remote_report_prompt) ;;
          esac
        }

        if [ -n "${ZSH_VERSION:-}" ]; then
          if autoload -Uz add-zsh-hook >/dev/null 2>&1 &&
             add-zsh-hook precmd __cmux_remote_report_prompt >/dev/null 2>&1; then
            :
          else
            __cmux_remote_add_zsh_precmd_fallback
          fi
        elif [ -n "${BASH_VERSION:-}" ]; then
          if declare -p PROMPT_COMMAND 2>/dev/null | grep -Eq '^declare -[^ ]*a[^ ]* PROMPT_COMMAND='; then
            __cmux_pc_seen=0
            for __cmux_pc in "${PROMPT_COMMAND[@]}"; do
              if [ "$__cmux_pc" = "__cmux_remote_report_prompt" ]; then
                __cmux_pc_seen=1
                break
              fi
            done
            if [ "$__cmux_pc_seen" -eq 0 ]; then
              PROMPT_COMMAND=(__cmux_remote_report_prompt "${PROMPT_COMMAND[@]}")
            fi
            unset __cmux_pc __cmux_pc_seen
          else
            case ";${PROMPT_COMMAND:-};" in
              *";__cmux_remote_report_prompt;"*) ;;
              *) PROMPT_COMMAND="__cmux_remote_report_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
            esac
          fi
        fi
        """
    }
}

struct RemoteRelayZshBootstrap {
    let shellStateDir: String

    private var sharedHistoryLines: [String] {
        [
            "if [ -z \"${HISTFILE:-}\" ] || [ \"$HISTFILE\" = \"\(shellStateDir)/.zsh_history\" ]; then export HISTFILE=\"$CMUX_REAL_ZDOTDIR/.zsh_history\"; fi",
        ]
    }

    var zshEnvLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshenv\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshenv\"",
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"\(shellStateDir)\" ]; then export CMUX_REAL_ZDOTDIR=\"$ZDOTDIR\"; fi",
        ] + sharedHistoryLines + [
            "export ZDOTDIR=\"\(shellStateDir)\"",
        ]
    }

    var zshProfileLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zprofile\" ] && source \"$CMUX_REAL_ZDOTDIR/.zprofile\"",
        ]
    }

    func zshRCLines(commonShellLines: [String]) -> [String] {
        sharedHistoryLines + [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zshrc\" ] && source \"$CMUX_REAL_ZDOTDIR/.zshrc\"",
        ] + commonShellLines
    }

    var zshLoginLines: [String] {
        [
            "[ -f \"$CMUX_REAL_ZDOTDIR/.zlogin\" ] && source \"$CMUX_REAL_ZDOTDIR/.zlogin\"",
        ]
    }
}
