import Foundation
import CmuxFoundation

enum SSHPTYAttachStartupCommandBuilder {
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
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .attach)
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
            lines.append(
                SSHForegroundAuthenticationRetryPolicy().processTreeTerminationShellFunction()
            )
        }
        lines.append("cmux_ssh_attach_lifecycle_id=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || exit 1")
        lines += [
            "cmux_ssh_attach_lifecycle_ended=0",
            "cmux_ssh_attach_auth_pid=",
            "cmux_ssh_attach_lifecycle_end() { if [ \"$cmux_ssh_attach_lifecycle_ended\" = 1 ]; then return; fi; cmux_ssh_attach_lifecycle_ended=1; \"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-session-end --lifecycle-only --workspace \"$CMUX_WORKSPACE_ID\" --surface \"${CMUX_SURFACE_ID:-}\" --terminal-lifecycle-id \"${CMUX_TERMINAL_LIFECYCLE_ID:-}\" --session-id \"$cmux_ssh_attach_session_id\" --lifecycle-id \"$cmux_ssh_attach_lifecycle_id\" >/dev/null 2>&1 || true; }",
            "cmux_ssh_attach_signal_exit() { cmux_ssh_attach_signal_status=\"$1\"; cmux_ssh_attach_signal_name=\"$2\"; if [ -n \"${cmux_ssh_attach_auth_pid:-}\" ]; then cmux_ssh_terminate_auth_process_tree \"$cmux_ssh_attach_auth_pid\" \"$$\"; wait \"$cmux_ssh_attach_auth_pid\" 2>/dev/null || true; cmux_ssh_attach_auth_pid=; \(backoffBuilder.signalHandlerBranches) elif [ \"${cmux_ssh_attach_auth_launching:-0}\" = 1 ]; then cmux_ssh_attach_pending_signal=\"$cmux_ssh_attach_signal_status\"; cmux_ssh_attach_pending_signal_name=\"$cmux_ssh_attach_signal_name\"; return; fi; cmux_ssh_attach_restore_terminal; trap - EXIT HUP INT TERM; cmux_ssh_attach_lifecycle_end; exit \"$cmux_ssh_attach_signal_status\"; }",
            "trap 'cmux_ssh_attach_lifecycle_end' EXIT",
            "trap 'cmux_ssh_attach_signal_exit 129 HUP' HUP",
            "trap 'cmux_ssh_attach_signal_exit 130 INT' INT",
            "trap 'cmux_ssh_attach_signal_exit 143 TERM' TERM",
        ]
        let requireExistingFlag = requireExisting ? " --require-existing" : ""
        let commandB64Flag = normalized(remoteCommand).map {
            " --command-b64 \(shellQuote(Data($0.utf8).base64EncodedString()))"
        } ?? ""
        let attachCommand = "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-pty-attach --wait\(requireExistingFlag) --workspace \"$CMUX_WORKSPACE_ID\" --session-id \"$cmux_ssh_attach_session_id\" --lifecycle-id \"$cmux_ssh_attach_lifecycle_id\" --attachment-id \"${CMUX_SURFACE_ID:-}\"\(commandB64Flag)"
        lines += [
            "cmux_ssh_attach_register_attempt() { cmux_ssh_attach_launch_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"${CMUX_SURFACE_ID:-}\\\",\\\"terminal_lifecycle_id\\\":\\\"${CMUX_TERMINAL_LIFECYCLE_ID:-}\\\",\\\"attempt_id\\\":\\\"$CMUX_SSH_ATTEMPT_ID\\\"}\"; CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=2 \"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc workspace.remote.terminal_session_launching \"$cmux_ssh_attach_launch_payload\" >/dev/null 2>&1; }",
            "cmux_ssh_attach_begin_attempt() { CMUX_SSH_ATTEMPT_ID=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || return 1; export CMUX_SSH_ATTEMPT_ID; cmux_ssh_attach_attempt_registration_retry=0; while ! cmux_ssh_attach_register_attempt; do cmux_ssh_attach_attempt_registration_retry=$((cmux_ssh_attach_attempt_registration_retry + 1)); if [ \"$cmux_ssh_attach_attempt_registration_retry\" -ge 3 ]; then return 1; fi; /bin/sleep 0.1; done; }",
            "cmux_ssh_attach_attempt() { cmux_ssh_attach_begin_attempt || return 1; \(attachCommand); }",
        ]
        lines += SSHPTYAttachRetryScriptBuilder().lines(
            command: "cmux_ssh_attach_attempt",
            reauthenticates: foregroundAuth != nil
        )
        return "/bin/sh -c \(shellQuote(lines.joined(separator: "\n")))"
    }

    static func restoredRemoteShellCommand(
        relayPort: Int,
        initialCommand: String? = nil,
        configuredRemoteCommand: String? = nil
    ) -> String {
        RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: relayPort,
            shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
            initialCommand: initialCommand,
            configuredRemoteCommand: configuredRemoteCommand,
            bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "cmux-zsh-integration.zsh"),
            bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "cmux-bash-integration.bash"),
            bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(named: "fish/config.fish")
        )
    }

    private static func foregroundAuthLines(_ auth: ForegroundAuth) -> [String] {
        let readinessInsideResolvedLock =
            foregroundAuthenticationReadyShellLines(
                auth,
                includeResolvedControlPath: true,
                requireSuccess: true,
                cliVariable: "CMUX_SSH_ATTACH_CLI"
            )
        let (sshCommand, reportsReadiness) =
            sshForegroundAuthCommand(
                auth,
                successShellLines: readinessInsideResolvedLock
            )
        var lines = [
            "cmux_ssh_attach_foreground_auth() {",
            "  \(sshCommand)",
            "cmux_ssh_auth_status=$?",
            "  if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then return \"$cmux_ssh_auth_status\"; fi",
        ]
        if !reportsReadiness {
            lines += foregroundAuthenticationReadyShellLines(
                auth,
                includeResolvedControlPath: false,
                requireSuccess: false,
                cliVariable: "cmux_ssh_attach_cli"
            )
        }
        lines += [
            "unset cmux_ssh_auth_status",
            "}",
        ]
        return lines
    }

    private static func sshForegroundAuthCommand(
        _ auth: ForegroundAuth,
        successShellLines: [String]
    ) -> (command: String, reportsReadiness: Bool) {
        let sharingOptions = SSHConnectionSharingOptions()
        var arguments = ["/usr/bin/ssh"]
        let options = SSHAgentSocketResolver().removingOptions(
            named: "RemoteCommand",
            from: sharingOptions.mergingDefaults(into: auth.sshOptions)
        )
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
        let preflight = sharingOptions.controlPathPreflightShellFunction(
            sshArguments: arguments,
            destination: auth.destination,
            options: options
        )
        let resolvedAuthenticationLockLines =
            resolvedControlMasterAuthenticationLockLines(
                sharingOptions: sharingOptions,
                sshArguments: arguments,
                destination: auth.destination,
                options: options
            )
        arguments += ["-T", auth.destination, "true"]
        let command = arguments.map(shellQuote).joined(separator: " ")
        guard let lockPath = sharingOptions.foregroundAuthenticationLockPath(
            destination: auth.destination,
            port: auth.port,
            options: options
        ) else {
            return (
                SSHForegroundAuthenticationRetryPolicy()
                    .classifyingTransientFailure(in: command),
                false
            )
        }
        let inFlightPath = lockPath + ".inflight"
        var lockedCommand = [
            "umask 077",
            "cmux_ssh_auth_inflight_path=\(shellQuote(inFlightPath))",
            "cmux_ssh_auth_lock_path=\(shellQuote(lockPath))",
            "printf '%s\\n' \"$$\" > \"$cmux_ssh_auth_inflight_path\" || exit 255",
            "cmux_ssh_clear_auth_inflight() { if [ \"$(/bin/cat -- \"$cmux_ssh_auth_inflight_path\" 2>/dev/null || true)\" = \"$$\" ]; then /bin/rm -f -- \"$cmux_ssh_auth_inflight_path\" 2>/dev/null || true; fi; }",
            "trap 'cmux_ssh_clear_auth_inflight' EXIT",
            "trap 'cmux_ssh_clear_auth_inflight; exit 129' HUP",
            "trap 'cmux_ssh_clear_auth_inflight; exit 130' INT",
            "trap 'cmux_ssh_clear_auth_inflight; exit 143' TERM",
            ": >> \"$cmux_ssh_auth_lock_path\" || exit 255",
            "zmodload zsh/system || exit 255",
            "zsystem flock -t 45 -e -f cmux_ssh_auth_lock_fd \"$cmux_ssh_auth_lock_path\" || exit 255",
        ]
        lockedCommand += resolvedAuthenticationLockLines
        lockedCommand += [
            preflight,
            preflight == nil ? nil : "cmux_ssh_preflight_control_path",
            "command \(command)",
            "cmux_ssh_auth_status=$?",
            "if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then exit \"$cmux_ssh_auth_status\"; fi",
        ].compactMap { $0 }
        lockedCommand += successShellLines
        lockedCommand += sharingOptions.successfulForegroundAuthenticationCleanupShellLines()
        lockedCommand.append("exit 0")
        let classifiedCommand = SSHForegroundAuthenticationRetryPolicy()
            .classifyingTransientFailure(in: lockedCommand.joined(separator: "\n"))
        return (
            "CMUX_SSH_ATTACH_CLI=\"$cmux_ssh_attach_cli\" \(classifiedCommand)",
            true
        )
    }

    private static func foregroundAuthenticationReadyShellLines(
        _ auth: ForegroundAuth,
        includeResolvedControlPath: Bool,
        requireSuccess: Bool,
        cliVariable: String
    ) -> [String] {
        let payload: String
        if includeResolvedControlPath {
            payload =
                "cmux_ssh_auth_payload=\"{\\\"workspace_id\\\":\\\"" +
                "$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"" +
                "$cmux_ssh_auth_token\\\",\\\"control_path\\\":\\\"" +
                "$cmux_ssh_resolved_control_path\\\"}\""
        } else {
            payload =
                "cmux_ssh_auth_payload=\"{\\\"workspace_id\\\":\\\"" +
                "$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"" +
                "$cmux_ssh_auth_token\\\"}\""
        }
        let failureHandling = requireSuccess ? " || exit 255" : " || true"
        return [
            "cmux_ssh_auth_token=\(shellQuote(auth.token))",
            payload,
            "\"$\(cliVariable)\" --socket \"$CMUX_SOCKET_PATH\" rpc " +
                "workspace.remote.foreground_auth_ready " +
                "\"$cmux_ssh_auth_payload\" >/dev/null 2>&1" +
                failureHandling,
            "unset cmux_ssh_auth_payload cmux_ssh_auth_token",
        ]
    }

    private static func resolvedControlMasterAuthenticationLockLines(
        sharingOptions: SSHConnectionSharingOptions,
        sshArguments: [String],
        destination: String,
        options: [String]
    ) -> [String] {
        guard sharingOptions.cmuxOwnedControlPath(in: options) != nil else {
            return []
        }
        let sshPrefix = sshArguments.map(shellQuote).joined(separator: " ")
        let quotedDestination = shellQuote(destination)
        let lockPrefix = URL(
            fileURLWithPath: sharingOptions.controlMasterLockDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(
            "cmux-ssh-\(sharingOptions.userID)-resolved-auth-",
            isDirectory: false
        )
        .path
        return [
            #"cmux_ssh_resolved_control_path="$(command \#(sshPrefix) -G \#(quotedDestination) 2>/dev/null | awk 'tolower($1) == "controlpath" { $1 = ""; sub(/^[[:space:]]+/, ""); print; exit }')" "#,
            "case \"$cmux_ssh_resolved_control_path\" in",
            "  /tmp/cmux-ssh-\(sharingOptions.userID)-*) ;;",
            "  *) exit 255 ;;",
            "esac",
            "cmux_ssh_resolved_control_basename=\"${cmux_ssh_resolved_control_path##*/}\"",
            "case \"$cmux_ssh_resolved_control_basename\" in ''|*[!A-Za-z0-9._-]*) exit 255 ;; esac",
            "cmux_ssh_resolved_auth_lock_path=\(shellQuote(lockPrefix))\"$cmux_ssh_resolved_control_basename.lock\"",
            ": >> \"$cmux_ssh_resolved_auth_lock_path\" || exit 255",
            "zsystem flock -t 45 -e -f cmux_ssh_resolved_auth_lock_fd \"$cmux_ssh_resolved_auth_lock_path\" || exit 255",
        ]
    }

    static func sshOptionsWithRestoreControlDefaults(_ options: [String], relayPort: Int? = nil) -> [String] {
        _ = relayPort
        return SSHConnectionSharingOptions().mergingDefaults(into: options)
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
