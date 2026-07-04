import Foundation
import CmuxFoundation

nonisolated enum SSHPTYAttachStartupCommandBuilder {
    struct ForegroundAuth {
        let destination: String
        let port: Int?
        let identityFile: String?
        let sshOptions: [String]
        let token: String
    }

    static func command(
        sessionID: String? = nil,
        foregroundAuth: ForegroundAuth? = nil,
        remoteCommand: String? = nil,
        requireExisting: Bool = true
    ) -> String {
        var lines = [
            "cmux_ssh_attach_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_ssh_attach_cli\" ] || [ ! -x \"$cmux_ssh_attach_cli\" ]; then cmux_ssh_attach_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_ssh_attach_cli\" ]; then printf '%s\\n' '[cmux] bundled CLI not found for SSH PTY attach.' >&2; exit 127; fi",
            "if [ -z \"${CMUX_SOCKET_PATH:-}\" ]; then printf '%s\\n' '[cmux] required configuration missing for SSH PTY attach.' >&2; exit 1; fi",
            "if [ -z \"${CMUX_WORKSPACE_ID:-}\" ]; then printf '%s\\n' '[cmux] required workspace context missing for SSH PTY attach.' >&2; exit 1; fi",
        ]
        if let sessionID = normalized(sessionID) {
            lines.append("cmux_ssh_attach_session_id=\(shellQuote(sessionID))")
        } else {
            lines += [
                "if [ -z \"${CMUX_SURFACE_ID:-}\" ]; then printf '%s\\n' '[cmux] required terminal context missing for SSH PTY attach.' >&2; exit 1; fi",
                "cmux_ssh_attach_session_id=\"ssh-$CMUX_WORKSPACE_ID-$CMUX_SURFACE_ID\"",
            ]
        }
        if let foregroundAuth {
            lines += foregroundAuthLines(foregroundAuth)
        }
        let requireExistingFlag = requireExisting ? " --require-existing" : ""
        // Carry the remote bootstrap compressed (zlib+base64) so a restored
        // session's attach command does not inline ≈280 KB of base64 into argv
        // and bloat `ps aux` (manaflow-ai/cmux#6738). Fall back to plain base64 if
        // compression somehow fails so the command is always well-formed.
        let commandFlag = normalized(remoteCommand).map { command -> String in
            if let compressed = command.deflatedBase64 {
                return " --command-zb64 \(shellQuote(compressed))"
            }
            return " --command-b64 \(shellQuote(Data(command.utf8).base64EncodedString()))"
        } ?? ""
        let attachCommand = "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-pty-attach --wait\(requireExistingFlag) --workspace \"$CMUX_WORKSPACE_ID\" --session-id \"$cmux_ssh_attach_session_id\" --attachment-id \"${CMUX_SURFACE_ID:-}\"\(commandFlag)"
        lines += retryingAttachLines(command: attachCommand)
        return "/bin/sh -c \(shellQuote(lines.joined(separator: "\n")))"
    }

    static func restoredRemoteShellCommand(relayPort: Int) -> String {
        RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: relayPort,
            shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
            bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "cmux-zsh-integration.zsh"),
            bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "cmux-bash-integration.bash"),
            bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "fish/config.fish")
        )
    }

    private static func retryingAttachLines(command: String) -> [String] {
        [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_limit=20 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_retry=0",
            "while :; do",
            "  \(command)",
            "  cmux_ssh_attach_status=$?",
            "  case \"$cmux_ssh_attach_status\" in 254|255) ;; *) exit \"$cmux_ssh_attach_status\" ;; esac",
            "  if [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m[cmux] remote PTY bridge closed; reattaching (attempt %s/%s).\\033[0m\\n' \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "done",
        ]
    }

    private static func foregroundAuthLines(_ auth: ForegroundAuth) -> [String] {
        let sshCommand = sshForegroundAuthCommand(auth)
        let quotedToken = shellQuote(auth.token)
        return [
            "\(sshCommand)",
            "cmux_ssh_auth_status=$?",
            "if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then exit \"$cmux_ssh_auth_status\"; fi",
            "cmux_ssh_auth_token=\(quotedToken)",
            "cmux_ssh_auth_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"$cmux_ssh_auth_token\\\"}\"",
            "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc workspace.remote.foreground_auth_ready \"$cmux_ssh_auth_payload\" >/dev/null 2>&1 || true",
            "unset cmux_ssh_auth_payload cmux_ssh_auth_status cmux_ssh_auth_token",
        ]
    }

    private static func sshForegroundAuthCommand(_ auth: ForegroundAuth) -> String {
        var arguments = ["ssh"]
        let options = sshOptionsWithRestoreControlDefaults(auth.sshOptions)
        if !hasSSHOptionKey(options, key: "ConnectTimeout") {
            arguments += ["-o", "ConnectTimeout=6"]
        }
        if !hasSSHOptionKey(options, key: "ServerAliveInterval") {
            arguments += ["-o", "ServerAliveInterval=20"]
        }
        if !hasSSHOptionKey(options, key: "ServerAliveCountMax") {
            arguments += ["-o", "ServerAliveCountMax=2"]
        }
        if let port = auth.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = normalized(auth.identityFile) {
            arguments += ["-i", identityFile]
        }
        for option in options {
            arguments += ["-o", option]
        }
        arguments += ["-T", auth.destination, "true"]
        return arguments.map(shellQuote).joined(separator: " ")
    }

    static func sshOptionsWithRestoreControlDefaults(_ options: [String], relayPort: Int? = nil) -> [String] {
        var merged = options.compactMap(normalized)
        let controlMaster = sshOptionValue(named: "ControlMaster", in: merged)
        let controlMasterDisabled = sshOptionValueIsDisabled(controlMaster)
        if controlMaster == nil {
            merged.append("ControlMaster=auto")
        }
        if !controlMasterDisabled {
            if !hasSSHOptionKey(merged, key: "ControlPersist") {
                merged.append("ControlPersist=600")
            }
            if !hasSSHOptionKey(merged, key: "ControlPath") {
                merged.append("ControlPath=\(restoreControlPathTemplate(relayPort: relayPort))")
            }
        }
        return merged
    }

    private static func restoreControlPathTemplate(relayPort: Int?) -> String {
        if let relayPort, relayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(relayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    static func sshOptionsSupportReusableForegroundAuth(_ options: [String]) -> Bool {
        guard !hasSSHOptionKey(options, key: "LocalCommand"),
              !hasSSHOptionKey(options, key: "PermitLocalCommand") else {
            return false
        }

        guard let controlPath = sshOptionValue(named: "ControlPath", in: options),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return false
        }

        if sshOptionValueIsDisabled(sshOptionValue(named: "ControlMaster", in: options)) {
            return false
        }

        return !sshOptionValueIsDisabled(
            sshOptionValue(named: "ControlPersist", in: options),
            zeroIsDisabled: false
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        SSHAgentSocketResolver().hasOptionKey(options, key: key)
    }

    private static func sshOptionValue(named name: String, in options: [String]) -> String? {
        SSHAgentSocketResolver().optionValue(named: name, in: options)
    }

    private static func sshOptionValueIsDisabled(_ rawValue: String?, zeroIsDisabled: Bool = true) -> Bool {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["no", "false", "off"].contains(normalized) || (zeroIsDisabled && normalized == "0")
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
