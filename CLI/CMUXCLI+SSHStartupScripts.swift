import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - SSH startup and interactive shell scripts
extension CMUXCLI {
    func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/.cmux/relay/\(max(remoteRelayPort, 0)).shell"
    }

    func bundledShellIntegrationScript(named fileName: String) -> String? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let executableURL = resolvedExecutableURL() {
            var current = executableURL.deletingLastPathComponent().standardizedFileURL
            while true {
                if current.lastPathComponent == "Contents" {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                }

                let projectMarker = current.appendingPathComponent("cmux.xcodeproj/project.pbxproj", isDirectory: false)
                if fileManager.fileExists(atPath: projectMarker.path) {
                    candidates.append(
                        current
                            .appendingPathComponent("Resources", isDirectory: true)
                            .appendingPathComponent("shell-integration", isDirectory: true)
                            .appendingPathComponent(fileName, isDirectory: false)
                    )
                    break
                }

                guard let parent = parentSearchURL(for: current) else {
                    break
                }
                current = parent
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("shell-integration", isDirectory: true)
                    .appendingPathComponent(fileName, isDirectory: false)
            )
        }

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }
            return contents
        }

        return nil
    }

    func buildInteractiveRemoteShellCommand(
        remoteRelayPort: Int,
        shellFeatures: String,
        terminfoSource: String? = nil
    ) -> String {
        let script = buildInteractiveRemoteShellScript(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        return posixShellCommand(script)
    }

    func interactiveRemoteTerminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$cmux_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    func interactiveRemoteShellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = Self.normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = Self.normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = Self.normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
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

    func interactiveRemoteRelayWarmupLines(remoteRelayPort: Int) -> [String] {
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
            "  cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "  cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  if [ -n \"$CMUX_SURFACE_ID\" ]; then",
            "    cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "    cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  fi",
            "  \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
            "  \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
            "fi",
            "unset CMUX_BOOTSTRAP_TTY cmux_relay_cli cmux_relay_tty cmux_relay_report_tty cmux_relay_ports_kick",
        ]
    }

    func baseSSHArguments(_ options: SSHCommandOptions, localCommandScript: String? = nil) -> [String] {
        let effectiveSSHOptions = effectiveSSHOptions(
            options.sshOptions,
            remoteRelayPort: options.remoteRelayPort
        )
        var parts: [String] = ["ssh"]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ConnectTimeout") {
            parts += ["-o", "ConnectTimeout=6"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveInterval") {
            parts += ["-o", "ServerAliveInterval=20"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "ServerAliveCountMax") {
            parts += ["-o", "ServerAliveCountMax=2"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SetEnv") {
            parts += ["-o", "SetEnv COLORTERM=truecolor"]
        }
        if !hasSSHOptionKey(effectiveSSHOptions, key: "SendEnv") {
            parts += ["-o", "SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION"]
        }
        if let port = options.port {
            parts += ["-p", String(port)]
        }
        if let identityFile = normalizedSSHIdentityPath(options.identityFile) {
            parts += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            parts += ["-o", option]
        }
        if let escapedLocalCommand = openSSHLocalCommandValue(shellScript: localCommandScript) {
            parts += ["-o", "PermitLocalCommand=yes"]
            parts += ["-o", "LocalCommand=\(escapedLocalCommand)"]
        }
        return parts
    }

    func localXtermGhosttyTerminfoSource() -> String? {
        let result = runProcess(
            executablePath: "/usr/bin/infocmp",
            arguments: ["-0", "-x", "xterm-ghostty"]
        )
        guard result.status == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    func sshOptionsWithControlSocketDefaults(
        _ options: [String],
        remoteRelayPort: Int? = nil
    ) -> [String] {
        var merged: [String] = []
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.append(trimmed)
        }
        let controlMaster = sshOptionValue(named: "ControlMaster", in: merged)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let controlMasterDisabled = ["no", "false", "off"].contains(controlMaster ?? "")
        if controlMaster == nil {
            merged.append("ControlMaster=auto")
        }
        if !controlMasterDisabled {
            if !hasSSHOptionKey(merged, key: "ControlPersist") {
                merged.append("ControlPersist=600")
            }
            if !hasSSHOptionKey(merged, key: "ControlPath") {
                merged.append("ControlPath=\(defaultSSHControlPathTemplate(remoteRelayPort: remoteRelayPort))")
            }
        }
        return merged
    }

    func scopedGhosttyShellFeaturesValue() -> String {
        let rawExisting = ProcessInfo.processInfo.environment["GHOSTTY_SHELL_FEATURES"] ?? ""
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

    func encodedRemoteBootstrapCommand(
        _ remoteBootstrapScript: String,
        remoteRelayPort: Int
    ) -> String {
        let encodedScript = Data(remoteBootstrapScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        var lines = remoteBootstrapTTYCaptureLines(remoteRelayPort: remoteRelayPort, includeRelayRPC: false)
        lines += [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-ssh-bootstrap.XXXXXX\") || exit 1",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || { rm -f \"$cmux_tmp\"; exit 1; }",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "rm -f \"$cmux_tmp\"",
            "exit $cmux_status",
        ]
        return lines.joined(separator: "\n")
    }

    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        controlPathPreflightShellFunction: String? = nil,
        retryPTYAttachStatus: Bool = false
    ) throws -> String {
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            retryPTYAttachStatus: retryPTYAttachStatus
        )
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort)
    }

    func buildReusableSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        controlPathPreflightShellFunction: String? = nil,
        retryPTYAttachStatus: Bool = false
    ) -> String {
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            retryPTYAttachStatus: retryPTYAttachStatus
        )
        return reusableShellStartupCommand(
            scriptBody: script,
            tempPrefix: "cmux-ssh-startup"
        )
    }

    private func buildReusableSSHPTYAttachStartupCommand(
        remoteShellCommand: String,
        remoteRelayPort: Int
    ) -> String {
        let attachScript = buildSSHPTYAttachScriptBody(
            remoteShellCommand: remoteShellCommand
        )
        return buildReusableSSHStartupCommand(
            sshCommand: attachScript,
            shellFeatures: "",
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: true,
            retryPTYAttachStatus: true
        )
    }

    func buildReusableForegroundAuthThenSSHPTYAttachStartupCommand(
        options: SSHCommandOptions,
        remoteShellCommand: String,
        localCommandScript: String?,
        controlPathPreflightShellFunction: String?
    ) -> String {
        var authArguments = baseSSHArguments(options, localCommandScript: localCommandScript)
        authArguments += ["-T", options.destination, "true"]
        let authCommand = authArguments.map(shellQuote).joined(separator: " ")
        let attachScript = buildSSHPTYAttachScriptBody(
            remoteShellCommand: remoteShellCommand
        )
        let scriptBody = [
            "command \(authCommand) <&0",
            "cmux_auth_status=$?",
            "if [ \"$cmux_auth_status\" -ne 0 ]; then exit \"$cmux_auth_status\"; fi",
            attachScript,
        ]
            .joined(separator: "\n")
        return buildReusableSSHStartupCommand(
            sshCommand: scriptBody,
            shellFeatures: "",
            remoteRelayPort: options.remoteRelayPort,
            isShellSnippet: true,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            retryPTYAttachStatus: true
        )
    }

    private func buildSSHPTYAttachScriptBody(
        remoteShellCommand: String
    ) -> String {
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let commandB64 = Data(remoteShellCommand.utf8).base64EncodedString()
        let attachCommand = [
            shellQuote(executablePath),
            "ssh-pty-attach",
            "--wait",
            "--workspace", "\"$cmux_ssh_pty_workspace_id\"",
            "--session-id", "\"$cmux_ssh_pty_session_id\"",
            "--attachment-id", "\"$cmux_ssh_pty_surface_id\"",
            "--command-b64", shellQuote(commandB64),
        ].joined(separator: " ")
        return [
            "cmux_ssh_pty_workspace_id=\"${CMUX_WORKSPACE_ID:-}\"",
            "cmux_ssh_pty_surface_id=\"${CMUX_SURFACE_ID:-}\"",
            "if [ -z \"$cmux_ssh_pty_workspace_id\" ]; then printf '%s\\n' '[cmux] required workspace context missing for SSH PTY attach.' >&2; exit 1; fi",
            "if [ -z \"$cmux_ssh_pty_surface_id\" ]; then printf '%s\\n' '[cmux] required terminal context missing for SSH PTY attach.' >&2; exit 1; fi",
            "cmux_ssh_pty_session_id=\"ssh-$cmux_ssh_pty_workspace_id-$cmux_ssh_pty_surface_id\"",
            "exec \(attachCommand)",
        ].joined(separator: "\n")
    }

    private func buildSSHStartupScriptBody(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool,
        controlPathPreflightShellFunction: String?,
        retryPTYAttachStatus: Bool
    ) -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        let trimmedControlPathPreflight = controlPathPreflightShellFunction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty {
            scriptLines.append(trimmedControlPathPreflight)
        }
        scriptLines += [
            "rm -f -- \"$0\" 2>/dev/null || true",
            "CMUX_SSH_SESSION_ENDED=0",
            "CMUX_SSH_STARTUP_PID=$$",
            "export CMUX_SSH_STARTUP_PID",
            "cmux_ssh_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_reconnect_limit=20 ;; esac",
            "cmux_ssh_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_reconnect_delay\" in ''|*[!0-9]*) cmux_ssh_reconnect_delay=2 ;; esac",
            "cmux_ssh_retry=0",
            "CMUX_SSH_CHILD_PID=",
            "CMUX_SSH_PENDING_SIGNAL=",
            "cmux_ssh_note() { if [ -t 2 ]; then printf \"$@\" >&2 || true; fi; }",
            "cmux_ssh_session_end() { if [ \"${CMUX_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; CMUX_SSH_SESSION_ENDED=1; \(lifecycleCleanup); }",
            // Pane-close signals are terminal lifecycle, not SSH transport lifecycle.
            // Avoid sending an extra TERM to a child that may own the shared ControlMaster path.
            "cmux_ssh_signal_exit() { cmux_ssh_signal_status=\"$1\"; if [ -z \"${CMUX_SSH_CHILD_PID:-}\" ]; then CMUX_SSH_PENDING_SIGNAL=\"$cmux_ssh_signal_status\"; return; fi; CMUX_SSH_SESSION_ENDED=1; trap - EXIT HUP INT TERM; exit \"$cmux_ssh_signal_status\"; }",
            "trap 'cmux_ssh_session_end' EXIT",
            "trap 'cmux_ssh_signal_exit 129' HUP",
            "trap 'cmux_ssh_signal_exit 130' INT",
            "trap 'cmux_ssh_signal_exit 143' TERM",
            "while :; do",
        ]
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty {
            scriptLines.append("  cmux_ssh_preflight_control_path")
        }
        // POSIX sh redirects stdin of an async command (`&`) to /dev/null when
        // job control is off (the default for `/bin/sh -c …`), so ssh would
        // never receive keystrokes from the surface PTY. Inheriting fd 0
        // explicitly with `<&0` overrides that default and keeps the wrapper's
        // own stdin (the terminal) wired into the backgrounded ssh process.
        if isShellSnippet {
            scriptLines += [
                "  (",
                "    \(sshCommand)",
                "  ) <&0 &",
            ]
        } else {
            scriptLines.append("  command \(sshCommand) <&0 &")
        }
        let retryableStatusPattern = retryPTYAttachStatus ? "254|255" : "255"
        scriptLines += [
            "  CMUX_SSH_CHILD_PID=$!",
            "  if [ -n \"${CMUX_SSH_PENDING_SIGNAL:-}\" ]; then cmux_ssh_signal_exit \"$CMUX_SSH_PENDING_SIGNAL\"; fi",
            "  wait \"$CMUX_SSH_CHILD_PID\"",
            "  cmux_ssh_status=$?",
            "  CMUX_SSH_CHILD_PID=",
            "  if [ \"$cmux_ssh_status\" -eq 0 ]; then break; fi",
            "  case \"$cmux_ssh_status\" in \(retryableStatusPattern)) ;; *) break ;; esac",
            "  if [ \"$cmux_ssh_retry\" -ge \"$cmux_ssh_reconnect_limit\" ]; then break; fi",
            "  cmux_ssh_retry=$((cmux_ssh_retry + 1))",
            "  cmux_ssh_note '\\n\\033[33m[cmux] ssh exited with status %s; reconnecting (attempt %s/%s).\\033[0m\\n\\033[2m[cmux] close this pane or press Ctrl-C to stop reconnecting.\\033[0m\\n' \"$cmux_ssh_status\" \"$cmux_ssh_retry\" \"$cmux_ssh_reconnect_limit\"",
            "  if [ \"$cmux_ssh_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_reconnect_delay\"; fi",
            "  if [ -n \"${CMUX_SSH_PENDING_SIGNAL:-}\" ]; then cmux_ssh_session_end; trap - EXIT HUP INT TERM; exit \"$CMUX_SSH_PENDING_SIGNAL\"; fi",
            "done",
            "trap - EXIT HUP INT TERM",
            "cmux_ssh_session_end",
            // Hold the pane so the user can see the error instead of silently falling
            // back to a local shell. Without this, Ghostty's PTY respawns a login shell
            // after the startup command exits, and a dead VM looks identical to "I never
            // SSH'd" — the surface shows `Last login: ... on ttys072` + a local prompt.
            "if [ \"$cmux_ssh_status\" -ne 0 ]; then",
            "  printf '\\n\\033[31m[cmux] ssh exited with status %s.\\033[0m\\n\\033[2m[cmux] the remote VM may have been paused, destroyed, or lost network.\\033[0m\\n\\033[2m[cmux] press Enter to close this pane.\\033[0m\\n' \"$cmux_ssh_status\" >&2 || true",
            "  IFS= read -r _cmux_dismiss_key 2>/dev/null || true",
            "fi",
            "exit $cmux_ssh_status",
        ]
        return scriptLines.joined(separator: "\n")
    }

    private func writeSSHStartupScript(_ scriptBody: String, remoteRelayPort: Int) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let scriptURL = tempDir.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return shellQuote(scriptURL.path)
    }

    private func reusableShellStartupCommand(
        scriptBody: String,
        tempPrefix: String
    ) -> String {
        let fullScript = "#!/bin/sh\n\(scriptBody)\n"
        let encodedScript = Data(fullScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        let wrapper = [
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/\(tempPrefix).XXXXXX\") || exit 1",
            "cmux_cleanup() { rm -f -- \"$cmux_tmp\" 2>/dev/null || true; }",
            "trap 'cmux_cleanup' EXIT HUP INT TERM",
            "(printf %s \(encodedLiteral) | base64 -d 2>/dev/null || printf %s \(encodedLiteral) | base64 -D 2>/dev/null) > \"$cmux_tmp\" || exit 1",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_cleanup",
            "unset cmux_tmp cmux_status",
            "unset -f cmux_cleanup 2>/dev/null || true",
            "exit $cmux_status",
        ].joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(wrapper))"
    }

    private func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${CMUX_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${CMUX_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${CMUX_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "\"${CMUX_BUNDLED_CLI_PATH}\" --socket \"${CMUX_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "elif command -v cmux >/dev/null 2>&1",
            "&& [ -n \"${CMUX_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${CMUX_SURFACE_ID:-}\" ]; then",
            "cmux ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${CMUX_WORKSPACE_ID}\" --surface \"${CMUX_SURFACE_ID}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

}
