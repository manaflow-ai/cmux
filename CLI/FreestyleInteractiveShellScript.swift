import Foundation

/// Builds the interactive Cloud VM bootstrap from the caller's cmux context.
struct FreestyleInteractiveShellScript: Sendable {
    private let environment: [String: String]
    private let suppressWelcome: Bool

    init(environment: [String: String], suppressWelcome: Bool = false) {
        self.environment = environment
        self.suppressWelcome = suppressWelcome
    }

    var text: String {
        """
        \(suppressWelcome ? "export CMUX_CLOUD_WELCOME=0" : ":")
        \(Self.cloudContextExports(environment: environment))
        export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
        hash -r 2>/dev/null || true
        if command -v zsh >/dev/null 2>&1; then
          touch "$HOME/.hushlogin" 2>/dev/null || true
          if [ ! -e "$HOME/.zshrc" ] || grep -q "cmux-managed zsh defaults" "$HOME/.zshrc" 2>/dev/null; then
            cat > "$HOME/.zshrc" <<'CMUX_USER_ZSHRC'
        # cmux-managed zsh defaults. Edit ~/.zshrc.local for personal overrides.
        mkdir -p "$HOME/.cmux" 2>/dev/null || true
        printf '%s' '/tmp/cmux-cloud-cli.sock' > "$HOME/.cmux/socket_addr" 2>/dev/null || true
        export CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH:-/tmp/cmux-cloud-cli.sock}"
        if [ -r /etc/cmux/zshrc ]; then
          source /etc/cmux/zshrc
        else
          export SHELL="$(command -v zsh)"
          autoload -Uz colors 2>/dev/null && colors
          setopt prompt_subst interactivecomments no_beep hist_ignore_dups share_history 2>/dev/null || true
          PROMPT_EOL_MARK=''
          unsetopt prompt_sp 2>/dev/null || true
          HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
          HISTSIZE="${HISTSIZE:-50000}"
          SAVEHIST="${SAVEHIST:-50000}"
          bindkey -e 2>/dev/null || true
          if [ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
            source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
            ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:-fg=8}"
          fi
          : ${CMUX_PROMPT_USER:=cmux-cloud}
          : ${CMUX_PROMPT_CHAR:=$'\\u03bb'}
          PROMPT='%F{magenta}${CMUX_PROMPT_USER}%f in %F{green}%~%f ${CMUX_PROMPT_CHAR} '
        fi
        [ -r "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
        if [ "${CMUX_CLOUD_WELCOME:-1}" != "0" ] && [ -z "${CMUX_CLOUD_WELCOME_SHOWN:-}" ] && [ -t 1 ]; then
          export CMUX_CLOUD_WELCOME_SHOWN=1
          printf '\\033[38;2;0;212;255m  ::\\033[0m\\n'
          printf '\\033[38;2;24;181;250m    ::::              \\033[38;2;0;212;255mc\\033[38;2;24;181;250mm\\033[38;2;48;150;245mu\\033[38;2;124;58;237mx cloud\\033[0m\\n'
          printf '\\033[38;2;48;150;245m      ::::::\\033[0m\\n'
          printf '\\033[38;2;72;119;241m        ::::::\\033[0m        \\033[38;2;130;130;140mpersistent cloud VM\\033[0m\\n'
          printf '\\033[38;2;96;88;239m      ::::::\\033[0m          \\033[38;2;130;130;140mready for coding agents\\033[0m\\n'
          printf '\\033[38;2;110;73;238m    ::::\\033[0m\\n'
          printf '\\033[38;2;124;58;237m  ::\\033[0m\\n'
          printf '\\n'
        fi
        CMUX_USER_ZSHRC
          fi
          if [ ! -e "$HOME/.zshrc.local" ]; then
            cat > "$HOME/.zshrc.local" <<'CMUX_LOCAL_ZSHRC'
        # Personal zsh overrides for this cloud VM.
        # Examples:
        #   CMUX_CLOUD_WELCOME=0
        #   CMUX_PROMPT_USER='cmux-cloud'
        #   CMUX_PROMPT_CHAR='>'
        #   PROMPT='%F{cyan}%n%f:%F{green}%~%f %# '
        CMUX_LOCAL_ZSHRC
          fi
          if command -v tmux >/dev/null 2>&1; then
            cmux_cloud_tty_scope="${CMUX_WORKSPACE_ID:-workspace}-${CMUX_SURFACE_ID:-surface}"
            if [ "$cmux_cloud_tty_scope" = "workspace-surface" ]; then
              cmux_cloud_tty_scope="default"
            fi
            cmux_cloud_tty_scope="$(printf '%s' "$cmux_cloud_tty_scope" | tr -c 'A-Za-z0-9_.-' '-')"
            cmux_cloud_tty_scope="${cmux_cloud_tty_scope#-}"
            cmux_cloud_tty_scope="${cmux_cloud_tty_scope%-}"
            [ -n "$cmux_cloud_tty_scope" ] || cmux_cloud_tty_scope=default
            if [ "$cmux_cloud_tty_scope" != default ] && [ "${CMUX_CLOUD_TMUX_SESSION:-}" = "cmux-cloud" ]; then
              unset CMUX_CLOUD_TMUX_SESSION
            fi
            if [ "$cmux_cloud_tty_scope" = default ]; then
              export CMUX_CLOUD_TMUX_SESSION="${CMUX_CLOUD_TMUX_SESSION:-cmux-cloud}"
            else
              export CMUX_CLOUD_TMUX_SESSION="${CMUX_CLOUD_TMUX_SESSION:-cmux-cloud-$cmux_cloud_tty_scope}"
            fi
            if ! tmux has-session -t "$CMUX_CLOUD_TMUX_SESSION" >/dev/null 2>&1; then
              tmux new-session -d -s "$CMUX_CLOUD_TMUX_SESSION" "exec zsh -l" >/dev/null 2>&1 || unset CMUX_CLOUD_TMUX_SESSION
            fi
            if [ -n "${CMUX_CLOUD_TMUX_SESSION:-}" ] && tmux has-session -t "$CMUX_CLOUD_TMUX_SESSION" >/dev/null 2>&1; then
              tmux set-option -t "$CMUX_CLOUD_TMUX_SESSION" status off >/dev/null 2>&1 || true
              tmux attach-session -t "$CMUX_CLOUD_TMUX_SESSION"
              cmux_tmux_status=$?
              [ "$cmux_tmux_status" -eq 0 ] && exit 0
            fi
          fi
          exec zsh -l
        fi
        exec "${SHELL:-/bin/sh}" -l
        """
    }

    private static func cloudContextExports(environment: [String: String]) -> String {
        var lines: [String] = []
        if let workspaceID = normalizedContextValue(environment["CMUX_WORKSPACE_ID"]) {
            lines.append("export CMUX_WORKSPACE_ID=\(shellSingleQuote(workspaceID))")
            lines.append("export CMUX_TAB_ID=\"$CMUX_WORKSPACE_ID\"")
        }
        if let surfaceID = normalizedContextValue(environment["CMUX_SURFACE_ID"]) {
            lines.append("export CMUX_SURFACE_ID=\(shellSingleQuote(surfaceID))")
            lines.append("export CMUX_PANEL_ID=\"$CMUX_SURFACE_ID\"")
        }
        return lines.isEmpty ? ":" : lines.joined(separator: "\n")
    }

    private static func normalizedContextValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
