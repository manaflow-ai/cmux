import CmuxFoundation
import Foundation

enum RemoteInteractiveShellBootstrapBuilder {
    static func script(
        remoteRelayPort: Int,
        shellFeatures: String,
        initialCommand: String? = nil,
        terminfoSource: String? = nil,
        bundledZshIntegration: String? = nil,
        bundledBashIntegration: String? = nil,
        bundledFishIntegration: String? = nil,
        terminalProfile: WorkspaceRemoteTerminalProfile = .shell
    ) -> String {
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let initialCommandBootstrap = RemoteInitialCommandBootstrap(command: initialCommand)
        let commonShellExportLines = commonShellLines(
            remoteRelayPort: remoteRelayPort,
            shellStateDir: shellStateDir,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash"; fi"#
        )
        bashShellLines.append(contentsOf: initialCommandBootstrap.posixInteractiveShellLines)
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let relayWarmupLines = relayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cmux_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$cmux_shell_dir\"",
        ]
        outerLines.append(contentsOf: initialCommandBootstrap.preparationLines)
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-zsh-integration.zsh\" <<'CMUXCMUXZSH'",
                bundledZshIntegration,
                "CMUXCMUXZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/cmux-bash-integration.bash\" <<'CMUXCMUXBASH'",
                bundledBashIntegration,
                "CMUXCMUXBASH",
            ]
        }
        if let bundledFishIntegration {
            outerLines += [
                "mkdir -p \"$cmux_shell_dir/fish\"",
                "cat > \"$cmux_shell_dir/fish/config.fish\" <<'CMUXCMUXFISH'",
                bundledFishIntegration,
                "CMUXCMUXFISH",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines += [
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshRCLines(commonShellLines: zshShellLines))
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshLoginLines + initialCommandBootstrap.posixInteractiveShellLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: "exec \"$CMUX_LOGIN_SHELL\" -il",
                tmuxShellCommand: "export CMUX_REAL_ZDOTDIR=\"${CMUX_REAL_ZDOTDIR:-${ZDOTDIR:-$HOME}}\"; export ZDOTDIR=\"\(shellStateDir)\"; exec \"${SHELL:-/bin/zsh}\" -il"
            ),
            "    ;;",
            "  bash)",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: [
            "if [ -f \"$HOME/.bash_profile\" ]; then",
            "  . \"$HOME/.bash_profile\"",
            "elif [ -f \"$HOME/.bash_login\" ]; then",
            "  . \"$HOME/.bash_login\"",
            "elif [ -f \"$HOME/.profile\" ]; then",
            "  . \"$HOME/.profile\"",
            "fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: "exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
                tmuxShellCommand: "exec \"${SHELL:-/bin/bash}\" --rcfile \"\(shellStateDir)/.bashrc\" -i"
            ),
            "    ;;",
            "  fish)",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        var fishInitCommands = ["source \"$CMUX_FISH_INTEGRATION_FILE\""]
        if let initialCommand = initialCommandBootstrap.fishInteractiveShellCommand {
            fishInitCommands.append(initialCommand)
        }
        let fishInitCommand = shellQuote(fishInitCommands.joined(separator: "; "))
        outerLines += [
            "    export CMUX_FISH_INTEGRATION_FILE=\"$cmux_shell_dir/fish/config.fish\"",
            "    export CMUX_FISH_USER_CONFIG_ALREADY_LOADED=1",
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: "exec \"$CMUX_LOGIN_SHELL\" -il --init-command \(fishInitCommand)",
                tmuxShellCommand: "export CMUX_FISH_INTEGRATION_FILE=\"\(shellStateDir)/fish/config.fish\"; export CMUX_FISH_USER_CONFIG_ALREADY_LOADED=1; exec \"${SHELL:-/bin/fish}\" -il --init-command \(fishInitCommand)"
            ),
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines.append(contentsOf: initialCommandBootstrap.fallbackShellLines)
        outerLines += [
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "",
                directShellCommand: "exec \"$CMUX_LOGIN_SHELL\" -i",
                tmuxShellCommand: "exec \"${SHELL:-/bin/sh}\" -i"
            ),
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    private static func terminalLaunchLine(
        profile: WorkspaceRemoteTerminalProfile,
        indentation: String,
        directShellCommand: String,
        tmuxShellCommand: String
    ) -> String {
        guard let sessionName = profile.tmuxSessionName else {
            return indentation + directShellCommand
        }
        let command = RemoteTmuxSessionCommandBuilder(
            sessionName: sessionName,
            shellCommand: tmuxShellCommand
        ).remoteShellCommand
        return indentation + "exec " + command
    }

    static func shellFeatures(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let rawExisting = environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    static func bundledShellIntegrationScript(
        named fileName: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let bundleResourceURL else { return nil }
        let url = bundleResourceURL
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    private static func commonShellLines(
        remoteRelayPort: Int,
        shellStateDir: String,
        shellFeatures: String,
        terminfoSource: String?
    ) -> [String] {
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var lines = terminalSetupLines(terminfoSource: terminfoSource)
        lines.append(contentsOf: RemoteShellEnvironment.utf8LocaleSetupLines())
        lines.append(contentsOf: shellExportLines(shellFeatures: shellFeatures))
        lines.append("export PATH=\"$HOME/.cmux/bin:$PATH\"")
        lines.append("export CMUX_BUNDLED_CLI_PATH=\"$HOME/.cmux/bin/cmux\"")
        lines.append("export CMUX_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            lines.append("export CMUX_SOCKET_PATH=\(relaySocket)")
        }
        // The assignment placeholders are replaced by `ssh-pty-attach` before
        // this script runs. Split the sentinel patterns so a missed replacement
        // does not export literal placeholder IDs into the remote shell.
        lines.append(contentsOf: [
            "cmux_workspace_id='__CMUX_WORKSPACE_ID__'",
            "case \"$cmux_workspace_id\" in \"\"|'__CMUX_''WORKSPACE_ID__') ;; *) export CMUX_WORKSPACE_ID=\"$cmux_workspace_id\"; export CMUX_TAB_ID=\"$cmux_workspace_id\" ;; esac",
            "cmux_surface_id='__CMUX_SURFACE_ID__'",
            "case \"$cmux_surface_id\" in \"\"|'__CMUX_''SURFACE_ID__') ;; *) export CMUX_SURFACE_ID=\"$cmux_surface_id\"; export CMUX_PANEL_ID=\"$cmux_surface_id\" ;; esac",
            "unset cmux_workspace_id cmux_surface_id",
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        return lines
    }

    static func terminalSetupLines(terminfoSource: String?) -> [String] {
        let trimmedTerminfoSource = terminfoSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTerminfoSource, !trimmedTerminfoSource.isEmpty else {
            // Without a bundled terminfo to install we can only probe what the
            // remote already has and fall back to a universally-present entry.
            return [
                "cmux_term='xterm-256color'",
                "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
                "  cmux_term='xterm-ghostty'",
                "fi",
                "export TERM=\"$cmux_term\"",
            ]
        }
        // Install the bundled xterm-ghostty terminfo *synchronously*, before
        // deciding TERM, so a full-screen TUI (e.g. Claude Code) never starts
        // against a TERM whose terminfo entry is missing or half-written.
        //
        // The previous design deferred `tic` to a background job and decided
        // TERM up front, so the first shell on a host without the entry got
        // xterm-256color while a later pass could select xterm-ghostty mid-write
        // and garble output (#6352). Here we compile into a private temp
        // directory on the same filesystem as ~/.terminfo, then move each
        // compiled entry into place with an atomic rename, so a concurrent reader
        // in another cmux ssh session sharing $HOME never observes a partially
        // written database. The temp directory comes from `mktemp` when present,
        // otherwise a per-process `$$` directory (unique among live processes) so
        // the atomic-rename path applies even without `mktemp` — no branch ever
        // compiles terminfo directly into ~/.terminfo.
        return [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "elif command -v tic >/dev/null 2>&1; then",
            "  mkdir -p \"$HOME/.terminfo\" 2>/dev/null",
            "  cmux_ti_tmp=$(mktemp -d \"$HOME/.terminfo.cmux.XXXXXX\" 2>/dev/null) || cmux_ti_tmp=''",
            "  if [ -z \"$cmux_ti_tmp\" ]; then",
            "    cmux_ti_tmp=\"$HOME/.terminfo.cmux.$$\"",
            "    rm -rf \"$cmux_ti_tmp\" 2>/dev/null",
            "    mkdir \"$cmux_ti_tmp\" 2>/dev/null || cmux_ti_tmp=''",
            "  fi",
            "  {",
            "    cat <<'CMUXTERMINFO'",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  } | {",
            "    if [ -n \"$cmux_ti_tmp\" ] && tic -x -o \"$cmux_ti_tmp\" - >/dev/null 2>&1; then",
            "      find \"$cmux_ti_tmp\" -type f 2>/dev/null | while IFS= read -r cmux_ti_file; do",
            "        cmux_ti_rel=${cmux_ti_file#\"$cmux_ti_tmp\"/}",
            "        cmux_ti_dest=\"$HOME/.terminfo/$cmux_ti_rel\"",
            "        mkdir -p \"$(dirname \"$cmux_ti_dest\")\" 2>/dev/null",
            "        mv -f \"$cmux_ti_file\" \"$cmux_ti_dest\" 2>/dev/null || cp -f \"$cmux_ti_file\" \"$cmux_ti_dest\" 2>/dev/null",
            "      done",
            "    fi",
            "  }",
            "  [ -n \"$cmux_ti_tmp\" ] && rm -rf \"$cmux_ti_tmp\" 2>/dev/null",
            "  if infocmp xterm-ghostty >/dev/null 2>&1; then",
            "    cmux_term='xterm-ghostty'",
            "  fi",
            "  unset cmux_ti_tmp cmux_ti_file cmux_ti_rel cmux_ti_dest 2>/dev/null || true",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
    }

    private static func shellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private static func relayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else {
            return []
        }
        return [
            "cmux_relay_cli=\"${CMUX_BUNDLED_CLI_PATH:-$HOME/.cmux/bin/cmux}\"",
            "if [ ! -x \"$cmux_relay_cli\" ]; then cmux_relay_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${CMUX_BOOTSTRAP_TTY:-}\"",
            "if [ -z \"$cmux_relay_tty\" ]; then cmux_relay_tty=\"$(tty 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${cmux_relay_tty##*/}\"",
            "if [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.cmux/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$cmux_relay_tty\" > \"$HOME/.cmux/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "fi",
            "if [ -n \"$cmux_relay_cli\" ] && [ -n \"$CMUX_WORKSPACE_ID\" ] && [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  (",
            "    cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "    cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "    if [ -n \"$CMUX_SURFACE_ID\" ]; then",
            "      cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "      cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "    fi",
            "    \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
            "    \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
            "  ) </dev/null >/dev/null 2>&1 &",
            "fi",
            "unset CMUX_BOOTSTRAP_TTY cmux_relay_cli cmux_relay_tty cmux_relay_report_tty cmux_relay_ports_kick",
        ]
    }

    private static func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/.cmux/relay/\(max(remoteRelayPort, 0)).shell"
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
