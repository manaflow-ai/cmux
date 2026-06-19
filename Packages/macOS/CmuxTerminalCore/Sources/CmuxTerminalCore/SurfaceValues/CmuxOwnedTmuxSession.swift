public import Foundation

public enum CmuxOwnedTmuxSession {
    public static let ownedOption = "@cmux-owned"
    public static let workspaceOption = "@cmux-workspace-id"
    public static let panelOption = "@cmux-panel-id"

    public static func sessionName(
        workspaceTitle: String?,
        workspaceDirectory: String?,
        workspaceId: UUID,
        panelTitle: String?,
        panelId: UUID
    ) -> String {
        let workspaceFallback = workspaceDirectory
            .flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmptyAfterTrimmingWhitespace }
            ?? "workspace-\(shortUUID(workspaceId))"
        let workspaceComponent = sanitizedComponent(
            workspaceTitle,
            fallback: workspaceFallback,
            maxLength: 36
        )
        let panelComponent = sanitizedComponent(panelTitle, fallback: "terminal", maxLength: 24)
        return "cmux-\(workspaceComponent)-\(panelComponent)-\(shortUUID(panelId))"
    }

    public static func attachCommand(sessionName: String) -> String {
        "tmux attach-session -t \(shellSingleQuoted(sessionName))"
    }

    @discardableResult
    public static func writeLauncherScript(
        sessionName: String,
        workspaceId: UUID,
        panelId: UUID,
        workingDirectory: String?,
        startupCommand: String?,
        fileManager: FileManager = .default,
        directory: URL? = nil,
        now: Date = Date()
    ) throws -> URL {
        let directory = try launcherDirectory(fileManager: fileManager, explicitDirectory: directory)
        pruneStaleLaunchers(in: directory, fileManager: fileManager, now: now)
        let fileURL = directory.appendingPathComponent(
            "cmux-owned-tmux-\(shortUUID(panelId))-\(UUID().uuidString.lowercased()).zsh"
        )
        let script = launcherScript(
            sessionName: sessionName,
            workspaceId: workspaceId,
            panelId: panelId,
            workingDirectory: workingDirectory,
            startupCommand: startupCommand
        )
        try script.write(to: fileURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.path)
        return fileURL
    }

    public static func sanitizedComponent(_ value: String?, fallback: String, maxLength: Int) -> String {
        let source = value?.nonEmptyAfterTrimmingWhitespace ?? fallback
        let folded = source.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        result.reserveCapacity(min(folded.count, maxLength))
        var lastWasSeparator = false
        for scalar in folded.lowercased().unicodeScalars {
            let isASCIIAlpha = (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
            let isASCIIDigit = (48...57).contains(Int(scalar.value))
            let isAllowedPunctuation = scalar == "." || scalar == "_" || scalar == "-"
            if isASCIIAlpha || isASCIIDigit || isAllowedPunctuation {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
            if result.count >= maxLength { break }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return trimmed.isEmpty ? sanitizedFallback(fallback, maxLength: maxLength) : trimmed
    }

    public static func launcherScript(
        sessionName: String,
        workspaceId: UUID,
        panelId: UUID,
        workingDirectory: String?,
        startupCommand: String?
    ) -> String {
        let session = shellSingleQuoted(sessionName)
        let workspace = shellSingleQuoted(workspaceId.uuidString)
        let panel = shellSingleQuoted(panelId.uuidString)
        let cwd = shellSingleQuoted(workingDirectory?.nonEmptyAfterTrimmingWhitespace ?? "")
        let startCommand = shellSingleQuoted(startupCommand?.nonEmptyAfterTrimmingWhitespace ?? "")
        let ownedOption = shellSingleQuoted(Self.ownedOption)
        let workspaceOption = shellSingleQuoted(Self.workspaceOption)
        let panelOption = shellSingleQuoted(Self.panelOption)
        return """
        #!/bin/zsh
        set -u

        _cmux_tmux="${CMUX_TMUX:-tmux}"
        _cmux_session=\(session)
        _cmux_workspace_id=\(workspace)
        _cmux_panel_id=\(panel)
        _cmux_cwd=\(cwd)
        _cmux_start_command=\(startCommand)

        _cmux_fallback() {
          print -u2 "cmux: tmux durability unavailable; starting without tmux"
          if [[ -n "$_cmux_start_command" ]]; then
            exec /bin/zsh -lic "$_cmux_start_command"
          fi
          exec -l "${SHELL:-/bin/zsh}"
        }

        _cmux_tmux_option() {
          "$_cmux_tmux" show-options -qv -t "$_cmux_session" "$1" 2>/dev/null || true
        }

        _cmux_session_exists() {
          "$_cmux_tmux" has-session -t "$_cmux_session" 2>/dev/null
        }

        _cmux_is_owned_by_this_panel() {
          [[ "$(_cmux_tmux_option \(ownedOption))" == "1" ]] || return 1
          [[ "$(_cmux_tmux_option \(workspaceOption))" == "$_cmux_workspace_id" ]] || return 1
          [[ "$(_cmux_tmux_option \(panelOption))" == "$_cmux_panel_id" ]] || return 1
          return 0
        }

        _cmux_should_export_env() {
          case "$1" in
            PATH|HOME|USER|LOGNAME|SHELL|TMPDIR|LANG|LC_*|TERM|TERM_PROGRAM|TERM_PROGRAM_VERSION|COLORTERM|EDITOR|VISUAL|PAGER|SSH_AUTH_SOCK|GPG_TTY|HTTPS_PROXY|HTTP_PROXY|ALL_PROXY|NO_PROXY|SSL_CERT_FILE|REQUESTS_CA_BUNDLE|NODE_OPTIONS|CMUX_*|CLAUDE_*|CODEX_*|GEMINI_*|CURSOR_*|BUN_*|NPM_*|PNPM_*|YARN_*|RUSTUP_*|CARGO_*|RUST*|GOROOT|GOPATH|GOPROXY|PYENV_*|VIRTUAL_ENV|CONDA_*|JAVA_HOME|MAVEN_*|GRADLE_*|NIX_*|DIRENV_*|XDG_*)
              return 0
              ;;
          esac
          return 1
        }

        _cmux_write_env_file() {
          local _cmux_old_umask _cmux_env_file _cmux_key
          _cmux_old_umask="$(umask)"
          umask 077
          _cmux_env_file="$(mktemp "${TMPDIR:-/tmp}/cmux-owned-tmux-env.XXXXXX")" || return 1
          umask "$_cmux_old_umask"
          : > "$_cmux_env_file"
          for _cmux_key in ${(k)parameters}; do
            [[ "$_cmux_key" == [A-Za-z_][A-Za-z0-9_]* ]] || continue
            _cmux_should_export_env "$_cmux_key" || continue
            typeset -px "$_cmux_key" >> "$_cmux_env_file" 2>/dev/null || true
          done
          print -r -- "$_cmux_env_file"
        }

        _cmux_write_pane_script() {
          local _cmux_env_file="$1"
          local _cmux_old_umask _cmux_pane_script _cmux_q_env _cmux_q_pane _cmux_q_start
          _cmux_old_umask="$(umask)"
          umask 077
          _cmux_pane_script="$(mktemp "${TMPDIR:-/tmp}/cmux-owned-tmux-pane.XXXXXX")" || return 1
          umask "$_cmux_old_umask"
          _cmux_q_env="$(printf "%q" "$_cmux_env_file")"
          _cmux_q_pane="$(printf "%q" "$_cmux_pane_script")"
          {
            print -r -- "#!/bin/zsh"
            print -r -- "set -u"
            print -r -- "source -- $_cmux_q_env"
            print -r -- "rm -f -- $_cmux_q_env $_cmux_q_pane"
            if [[ -n "$_cmux_start_command" ]]; then
              _cmux_q_start="$(printf "%q" "$_cmux_start_command")"
              print -r -- "exec /bin/zsh -lic $_cmux_q_start"
            else
              print -r -- 'exec -l "${SHELL:-/bin/zsh}"'
            fi
          } > "$_cmux_pane_script" || return 1
          chmod 700 "$_cmux_pane_script" 2>/dev/null || true
          print -r -- "$_cmux_pane_script"
        }

        _cmux_create_session() {
          local _cmux_env_file _cmux_pane_script _cmux_q_pane
          _cmux_env_file="$(_cmux_write_env_file)" || return 1
          _cmux_pane_script="$(_cmux_write_pane_script "$_cmux_env_file")" || {
            rm -f -- "$_cmux_env_file"
            return 1
          }
          _cmux_q_pane="$(printf "%q" "$_cmux_pane_script")"
          local -a _cmux_args
          _cmux_args=(new-session -d -s "$_cmux_session")
          if [[ -n "$_cmux_cwd" ]]; then
            _cmux_args+=(-c "$_cmux_cwd")
          fi
          _cmux_args+=("/bin/zsh $_cmux_q_pane")
          if ! "$_cmux_tmux" "${_cmux_args[@]}"; then
            rm -f -- "$_cmux_env_file" "$_cmux_pane_script"
            return 1
          fi
          "$_cmux_tmux" set-option -q -t "$_cmux_session" \(ownedOption) 1 2>/dev/null || true
          "$_cmux_tmux" set-option -q -t "$_cmux_session" \(workspaceOption) "$_cmux_workspace_id" 2>/dev/null || true
          "$_cmux_tmux" set-option -q -t "$_cmux_session" \(panelOption) "$_cmux_panel_id" 2>/dev/null || true
        }

        if ! command -v "$_cmux_tmux" >/dev/null 2>&1; then
          _cmux_fallback
        fi

        if _cmux_session_exists; then
          if ! _cmux_is_owned_by_this_panel; then
            print -u2 "cmux: tmux session $_cmux_session exists but is not owned by this panel"
            _cmux_fallback
          fi
        else
          if ! _cmux_create_session && ! _cmux_session_exists; then
            _cmux_fallback
          fi
        fi

        rm -f -- "$0" 2>/dev/null || true
        exec "$_cmux_tmux" attach-session -t "$_cmux_session"
        """
    }

    private static func launcherDirectory(fileManager: FileManager, explicitDirectory: URL?) throws -> URL {
        let directory: URL
        if let explicitDirectory {
            directory = explicitDirectory
        } else if let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            directory = cachesDirectory
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("owned-tmux-launchers", isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-owned-tmux-launchers", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pruneStaleLaunchers(in directory: URL, fileManager: FileManager, now: Date) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for url in contents where url.lastPathComponent.hasPrefix("cmux-owned-tmux-") {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func sanitizedFallback(_ fallback: String, maxLength: Int) -> String {
        if fallback == "terminal" { return fallback }
        let sanitized = sanitizedComponent("terminal", fallback: "terminal", maxLength: maxLength)
        return sanitized.isEmpty ? "terminal" : sanitized
    }

    private static func shortUUID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nonEmptyAfterTrimmingWhitespace: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
