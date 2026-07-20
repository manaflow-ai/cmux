import Foundation
import CmuxCore
import CmuxFoundation
#if canImport(Security)
import Security
#endif

extension SessionRemoteWorkspaceSnapshot {
    func workspaceConfiguration(
        localSocketPath: String? = nil,
        allowPersistentPTYRestore: Bool = true,
        preserveSSHOptions: Bool = false,
        agentSocketPath overrideAgentSocketPath: String? = nil
    ) -> WorkspaceRemoteConfiguration? {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }
        let normalizedManagedCloudVMID = WorkspaceRemoteConfiguration.normalizedOptionalValue(managedCloudVMID)
        if transport == .websocket {
            guard let normalizedManagedCloudVMID else { return nil }
            return WorkspaceRemoteConfiguration(
                transport: .websocket,
                terminalTransport: .ssh,
                destination: normalizedDestination,
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: WorkspaceRemoteConfiguration.normalizedOptionalValue(localSocketPath),
                managedCloudVMID: normalizedManagedCloudVMID,
                terminalStartupCommand: Self.defaultFreestyleSSHAttachCommand(vmID: normalizedManagedCloudVMID),
                agentSocketPath: nil,
                daemonWebSocketEndpoint: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: Self.defaultFreestylePersistentDaemonSlot,
                skipDaemonBootstrap: true
            )
        }
        guard transport == .ssh else { return nil }
        let normalizedPort = port.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }

        let normalizedPersistentDaemonSlot = WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(persistentDaemonSlot)
        let normalizedLocalSocketPath = WorkspaceRemoteConfiguration.normalizedOptionalValue(localSocketPath)
        let normalizedRelayPort = relayPort.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }
        let preservedOptions = preserveSSHOptions
            ? WorkspaceRemoteConfiguration.trimmedSSHOptions(sshOptions)
            : Self.normalizedSSHOptions(sshOptions)
        let optionsWithRestoreControlDefaults = SSHPTYAttachStartupCommandBuilder.sshOptionsWithRestoreControlDefaults(
            preservedOptions,
            relayPort: normalizedRelayPort
        )
        let fallbackSSHOptions = preserveSSHOptions
            ? Self.normalizedSSHOptions(preservedOptions)
            : preservedOptions
        let managedCloudVMID = normalizedManagedCloudVMID
            ?? Self.legacyDefaultFreestyleVMID(destination: normalizedDestination, skipDaemonBootstrap: skipDaemonBootstrap)
        let defaultFreestyleVMID = skipDaemonBootstrap == true ? managedCloudVMID : nil
        let requestedTerminalTransport = terminalTransport ?? .ssh
        let restoredTerminalTransport: WorkspaceRemoteTerminalTransport = requestedTerminalTransport
            .isSupportedForRemoteConfiguration(
                managementTransport: .ssh,
                skipDaemonBootstrap: skipDaemonBootstrap == true
            )
            ? requestedTerminalTransport
            : .ssh
        let restoredTerminalProfile: WorkspaceRemoteTerminalProfile = defaultFreestyleVMID == nil
            ? (terminalProfile ?? .shell)
            : .shell
        let effectivePersistentDaemonSlot = normalizedPersistentDaemonSlot
            ?? (defaultFreestyleVMID == nil ? nil : Self.defaultFreestylePersistentDaemonSlot)
        let preservePTYSession =
            restoredTerminalTransport == .ssh &&
            allowPersistentPTYRestore &&
            preserveAfterTerminalExit == true &&
            skipDaemonBootstrap != true &&
            effectivePersistentDaemonSlot != nil &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil &&
            SSHPTYAttachStartupCommandBuilder.sshOptionsSupportReusableForegroundAuth(optionsWithRestoreControlDefaults)
        let restoreMoshRelayNamespace =
            restoredTerminalTransport == .mosh &&
            skipDaemonBootstrap != true &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil
        let restoreRelayNamespace = preservePTYSession || restoreMoshRelayNamespace
        let restoreDefaultFreestyleSSHD = defaultFreestyleVMID != nil
        let restoredSSHOptions = preservePTYSession ? optionsWithRestoreControlDefaults : fallbackSSHOptions
        let foregroundAuthToken = preservePTYSession ? UUID().uuidString.lowercased() : nil
        let foregroundAuth = foregroundAuthToken.map {
            SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: normalizedDestination,
                port: normalizedPort,
                identityFile: Self.normalizedIdentityPath(identityFile),
                sshOptions: restoredSSHOptions,
                token: $0
            )
        }
        let restoredRelayID = restoreRelayNamespace
            ? UUID().uuidString.lowercased()
            : nil
        let restoredRelayToken = restoreRelayNamespace
            ? Self.restoreRelayTokenHex()
            : nil
        let restoredRemoteShellCommand = preservePTYSession
            ? normalizedRelayPort.map(SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(relayPort:))
            : nil
        return WorkspaceRemoteConfiguration(
            transport: transport,
            terminalTransport: restoredTerminalTransport,
            terminalProfile: restoredTerminalProfile,
            destination: normalizedDestination,
            port: normalizedPort,
            identityFile: Self.normalizedIdentityPath(identityFile),
            sshOptions: restoredSSHOptions,
            localProxyPort: nil,
            relayPort: restoreRelayNamespace ? normalizedRelayPort : nil,
            relayID: restoredRelayID,
            relayToken: restoredRelayToken,
            localSocketPath: restoreRelayNamespace ? normalizedLocalSocketPath : nil,
            managedCloudVMID: managedCloudVMID,
            terminalStartupCommand: {
                if preservePTYSession {
                    return SSHPTYAttachStartupCommandBuilder.command(
                        foregroundAuth: foregroundAuth,
                        remoteCommand: restoredRemoteShellCommand,
                        // Restored panels get explicit require-existing attach commands with their
                        // persisted session IDs; this workspace default is for new panes.
                        requireExisting: false
                    )
                }
                if let defaultFreestyleVMID {
                    return Self.defaultFreestyleSSHAttachCommand(vmID: defaultFreestyleVMID)
                }
                let fallbackCommand = sshReconnectCommand(
                    destination: normalizedDestination,
                    port: normalizedPort,
                    sshOptions: restoredSSHOptions,
                    terminalProfile: restoredTerminalProfile
                )
                guard restoredTerminalTransport == .mosh,
                      let fallbackCommand else {
                    return fallbackCommand
                }
                return moshReconnectCommand(
                    destination: normalizedDestination,
                    port: normalizedPort,
                    sshOptions: restoredSSHOptions,
                    terminalProfile: restoredTerminalProfile,
                    remoteRelayPort: restoreMoshRelayNamespace ? normalizedRelayPort : nil,
                    sshFallbackCommand: fallbackCommand
                )
            }(),
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: restoredSSHOptions,
                explicitAgentSocketPath: overrideAgentSocketPath
            ),
            daemonWebSocketEndpoint: nil,
            preserveAfterTerminalExit: preservePTYSession || restoreDefaultFreestyleSSHD,
            persistentDaemonSlot: (preservePTYSession || restoreDefaultFreestyleSSHD) ? effectivePersistentDaemonSlot : nil,
            skipDaemonBootstrap: skipDaemonBootstrap == true
        )
    }

    private static func restoreRelayTokenHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
#if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
#endif
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func sshReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String]? = nil,
        terminalProfile: WorkspaceRemoteTerminalProfile = .shell
    ) -> String? {
        var arguments = sshBootstrapArguments(
            port: normalizedPort,
            sshOptions: reconnectSSHOptions
        )
        let normalizedOptions = reconnectSSHOptions ?? Self.normalizedSSHOptions(sshOptions)
        if !Self.hasSSHOptionKey(normalizedOptions, key: "RequestTTY") {
            arguments.append("-tt")
        }
        if !terminalProfile.remoteCommandArguments.isEmpty {
            arguments = [arguments[0]]
                + SSHHostConfiguredRemoteCommand().overrideArguments
                + arguments.dropFirst()
        }
        arguments.append(normalizedDestination)
        arguments.append(contentsOf: terminalProfile.remoteCommandArguments)
        return arguments.map(Self.shellQuote).joined(separator: " ")
    }

    private func moshReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String],
        terminalProfile: WorkspaceRemoteTerminalProfile,
        remoteRelayPort: Int?,
        sshFallbackCommand: String
    ) -> String {
        let sshArguments = sshBootstrapArguments(
            port: normalizedPort,
            sshOptions: reconnectSSHOptions
        )
        let moshSSHArguments = [sshArguments[0]]
            + SSHHostConfiguredRemoteCommand().overrideArguments
            + sshArguments.dropFirst()
        var remoteCommandArguments = terminalProfile.remoteCommandArguments
        var preparationShellScript: String?
        var effectiveSSHFallbackCommand = sshFallbackCommand
        if let remoteRelayPort {
            let remoteBootstrapScript = RemoteInteractiveShellBootstrapBuilder.script(
                remoteRelayPort: remoteRelayPort,
                shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
                bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "cmux-zsh-integration.zsh"
                ),
                bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "cmux-bash-integration.bash"
                ),
                bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "fish/config.fish"
                ),
                terminalProfile: terminalProfile
            )
            if let staging = RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: moshSSHArguments,
                destination: normalizedDestination,
                remoteRelayPort: remoteRelayPort,
                bootstrapScript: remoteBootstrapScript
            ) {
                remoteCommandArguments = staging.remoteExecutionCommandArguments
                preparationShellScript = staging.preparationShellScript
                effectiveSSHFallbackCommand = stagedSSHFallbackCommand(
                    staging: staging,
                    sshArguments: moshSSHArguments,
                    destination: normalizedDestination,
                    sshOptions: reconnectSSHOptions
                )
            }
        }
        return MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: moshSSHArguments,
            sessionSSHArguments: moshSSHArguments,
            destination: normalizedDestination,
            remoteCommandArguments: remoteCommandArguments,
            preparationShellScript: preparationShellScript,
            sshFallbackCommand: effectiveSSHFallbackCommand,
            localMoshMissingMessage: String(
                localized: "cli.ssh.mosh.localMissing",
                defaultValue: "[cmux] Mosh is not installed locally; continuing over SSH."
            ),
            localMoshUnsupportedMessage: String(
                localized: "cli.ssh.mosh.localUnsupported",
                defaultValue: "[cmux] The local Mosh client lacks required SSH integration; continuing over SSH."
            ),
            remoteMoshMissingMessage: String(
                localized: "cli.ssh.mosh.remoteMissing",
                defaultValue: "[cmux] mosh-server is not installed on the remote host; continuing over SSH."
            ),
            remoteMoshProbeFailedMessage: String(
                localized: "cli.ssh.mosh.probeFailed",
                defaultValue: "[cmux] Could not verify remote Mosh support; continuing over SSH."
            )
        ).command()
    }

    private func stagedSSHFallbackCommand(
        staging: RemoteBootstrapStagingCommandBuilder,
        sshArguments: [String],
        destination: String,
        sshOptions: [String]
    ) -> String {
        var terminalArguments = sshArguments
        if !Self.hasSSHOptionKey(sshOptions, key: "RequestTTY") {
            terminalArguments.append("-tt")
        }
        terminalArguments.append(destination)
        terminalArguments.append(contentsOf: staging.remoteExecutionCommandArguments)
        let invocation = terminalArguments.map(Self.shellQuote).joined(separator: " ")
        let script = [
            staging.preparationShellScript,
            "if [ \"$cmux_remote_install_status\" -ne 0 ]; then exit \"$cmux_remote_install_status\"; fi",
            "unset cmux_remote_install_status",
            "exec \(invocation)",
        ].joined(separator: "\n")
        return "/bin/sh -c \(Self.shellQuote(script))"
    }

    private func sshBootstrapArguments(
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String]? = nil
    ) -> [String] {
        var arguments = ["ssh"]
        if let normalizedPort {
            arguments += ["-p", String(normalizedPort)]
        }
        if let identityFile = Self.normalizedIdentityPath(identityFile) {
            arguments += ["-i", identityFile]
        }
        let normalizedOptions = reconnectSSHOptions ?? Self.normalizedSSHOptions(sshOptions)
        for option in normalizedOptions {
            arguments += ["-o", option]
        }
        return arguments
    }

    private static func normalizedIdentityPath(_ value: String?) -> String? {
        WorkspaceRemoteConfiguration.normalizedIdentityPath(value)
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteConfiguration.durableSSHOptions(options)
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        WorkspaceRemoteConfiguration.hasSSHOptionKey(options, key: key)
    }

    private static let defaultFreestylePersistentDaemonSlot = "cmux-default-freestyle-sshd-v1"

    private static func legacyDefaultFreestyleVMID(destination: String, skipDaemonBootstrap: Bool?) -> String? {
        guard skipDaemonBootstrap == true else { return nil }
        let pattern = #"^([A-Za-z0-9._-]+)\+cmux@vm-ssh\.freestyle\.sh$"#
        guard let match = destination.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = String(destination[match])
        guard let plusRange = matched.range(of: "+cmux@vm-ssh.freestyle.sh") else {
            return nil
        }
        return String(matched[..<plusRange.lowerBound])
    }

    private static func defaultFreestyleSSHAttachCommand(vmID: String) -> String {
        let lines = [
            "cmux_freestyle_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_freestyle_cli\" ] || [ ! -x \"$cmux_freestyle_cli\" ]; then cmux_freestyle_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_freestyle_cli\" ]; then printf '%s\\n' '[cmux] bundled CLI not found for Cloud VM SSH attach.' >&2; exit 127; fi",
            "CMUX_SSH_RECONNECT_LIMIT=\"${CMUX_SSH_RECONNECT_LIMIT:-86400}\"",
            "CMUX_SSH_RECONNECT_DELAY_SECONDS=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$CMUX_SSH_RECONNECT_LIMIT}\"",
            "CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\"${CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$CMUX_SSH_RECONNECT_DELAY_SECONDS}\"",
            "export CMUX_SSH_RECONNECT_LIMIT CMUX_SSH_RECONNECT_DELAY_SECONDS",
            "export CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT CMUX_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
            "cmux_freestyle_attach() {",
            "  if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then",
            "    \"$cmux_freestyle_cli\" --socket \"$CMUX_SOCKET_PATH\" vm-pty-attach --id \(shellQuote(vmID)) --default-freestyle-sshd",
            "  else",
            "    \"$cmux_freestyle_cli\" vm-pty-attach --id \(shellQuote(vmID)) --default-freestyle-sshd",
            "  fi",
            "}",
            "cmux_freestyle_retry=0",
            "while :; do",
            "  if [ \"$cmux_freestyle_retry\" -gt 0 ]; then",
            "    export CMUX_CLOUD_RECONNECT_ATTEMPT=\"$cmux_freestyle_retry\"",
            "  else",
            "    unset CMUX_CLOUD_RECONNECT_ATTEMPT",
            "  fi",
            "  cmux_freestyle_attach",
            "  cmux_freestyle_status=$?",
            "  case \"$cmux_freestyle_status\" in 254|255) ;; *) exit \"$cmux_freestyle_status\" ;; esac",
            "  if [ \"$cmux_freestyle_retry\" -ge \"$CMUX_SSH_RECONNECT_LIMIT\" ]; then exit \"$cmux_freestyle_status\"; fi",
            "  cmux_freestyle_retry=$((cmux_freestyle_retry + 1))",
            "  sleep \"$CMUX_SSH_RECONNECT_DELAY_SECONDS\"",
            "done",
        ]
        return "/bin/sh -c \(shellQuote(lines.joined(separator: "\n")))"
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
