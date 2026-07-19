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
        lines.append("cmux_ssh_attach_lifecycle_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || exit 1")
        lines += [
            "cmux_ssh_attach_lifecycle_ended=0",
            "cmux_ssh_attach_lifecycle_end() { if [ \"$cmux_ssh_attach_lifecycle_ended\" = 1 ]; then return; fi; cmux_ssh_attach_lifecycle_ended=1; \"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-session-end --lifecycle-only --workspace \"$CMUX_WORKSPACE_ID\" --surface \"${CMUX_SURFACE_ID:-}\" --session-id \"$cmux_ssh_attach_session_id\" --lifecycle-id \"$cmux_ssh_attach_lifecycle_id\" >/dev/null 2>&1 || true; }",
            "cmux_ssh_attach_signal_exit() { cmux_ssh_attach_signal_status=\"$1\"; trap - EXIT HUP INT TERM; cmux_ssh_attach_lifecycle_end; exit \"$cmux_ssh_attach_signal_status\"; }",
            "trap 'cmux_ssh_attach_lifecycle_end' EXIT",
            "trap 'cmux_ssh_attach_signal_exit 129' HUP",
            "trap 'cmux_ssh_attach_signal_exit 130' INT",
            "trap 'cmux_ssh_attach_signal_exit 143' TERM",
        ]
        let requireExistingFlag = requireExisting ? " --require-existing" : ""
        let commandB64Flag = normalized(remoteCommand).map {
            " --command-b64 \(shellQuote(Data($0.utf8).base64EncodedString()))"
        } ?? ""
        let attachCommand = "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-pty-attach --wait\(requireExistingFlag) --workspace \"$CMUX_WORKSPACE_ID\" --session-id \"$cmux_ssh_attach_session_id\" --lifecycle-id \"$cmux_ssh_attach_lifecycle_id\" --attachment-id \"${CMUX_SURFACE_ID:-}\"\(commandB64Flag)"
        lines += retryingAttachLines(command: attachCommand, reauthenticates: foregroundAuth != nil)
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

    private static func retryingAttachLines(command: String, reauthenticates: Bool) -> [String] {
        // Retryable 254|255 is owned by SSHPTYAttachExitCode in the CLI target; keep in sync with CMUXCLI.sshPTYAttachRetryLoopLines.
        let reauthenticate = reauthenticates ? "cmux_ssh_attach_reauth_required=1" : ":"
        return [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in '') cmux_ssh_attach_reconnect_limit='∞'; cmux_ssh_attach_reconnect_unbounded=1 ;; *[!0-9]*) cmux_ssh_attach_reconnect_limit=20; cmux_ssh_attach_reconnect_unbounded=0 ;; *) cmux_ssh_attach_reconnect_unbounded=0 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_reconnect_max_delay=\"${CMUX_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$cmux_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) cmux_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi",
            "cmux_ssh_attach_reconnect_initial_delay=\"$cmux_ssh_attach_reconnect_delay\"",
            "cmux_ssh_attach_retry=0",
            "cmux_ssh_attach_reauth_required=0",
            "while :; do",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    cmux_ssh_attach_foreground_auth",
            "    cmux_ssh_attach_status=$?",
            "    if [ \"$cmux_ssh_attach_status\" -eq 0 ]; then cmux_ssh_attach_reauth_required=0; elif [ \"$cmux_ssh_attach_status\" -ne 255 ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 1 ] || [ \"$cmux_ssh_attach_retry\" -lt \"$cmux_ssh_attach_reconnect_limit\" ]; then cmux_ssh_attach_can_retry=1; else cmux_ssh_attach_can_retry=0; fi",
            "  CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$cmux_ssh_attach_can_retry\" \(command)",
            "  cmux_ssh_attach_status=$?",
            "  case \"$cmux_ssh_attach_status\" in 254) cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_initial_delay\" ;; 255) \(reauthenticate) ;; *) exit \"$cmux_ssh_attach_status\" ;; esac",
            "  fi",
            "  if [ \"$cmux_ssh_attach_reconnect_unbounded\" -eq 0 ] && [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m[cmux] remote PTY bridge closed; reattaching (attempt %s/%s).\\033[0m\\n' \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -lt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=$((cmux_ssh_attach_reconnect_delay * 2)); if [ \"$cmux_ssh_attach_reconnect_delay\" -gt \"$cmux_ssh_attach_reconnect_max_delay\" ]; then cmux_ssh_attach_reconnect_delay=\"$cmux_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ]
    }

    private static func foregroundAuthLines(_ auth: ForegroundAuth) -> [String] {
        let sshCommand = sshForegroundAuthCommand(auth)
        let quotedToken = shellQuote(auth.token)
        return [
            "cmux_ssh_attach_foreground_auth() {",
            "  \(sshCommand)",
            "cmux_ssh_auth_status=$?",
            "  if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then return \"$cmux_ssh_auth_status\"; fi",
            "cmux_ssh_auth_token=\(quotedToken)",
            "cmux_ssh_auth_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"$cmux_ssh_auth_token\\\"}\"",
            "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc workspace.remote.foreground_auth_ready \"$cmux_ssh_auth_payload\" >/dev/null 2>&1 || true",
            "unset cmux_ssh_auth_payload cmux_ssh_auth_status cmux_ssh_auth_token",
            "}",
            "cmux_ssh_attach_foreground_auth",
            "cmux_ssh_auth_status=$?",
            "if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then exit \"$cmux_ssh_auth_status\"; fi",
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
        // The command-line `true` below conflicts with a host-configured
        // RemoteCommand unless overridden (issue #7246).
        arguments += SSHHostConfiguredRemoteCommand().overrideArguments
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
