import CmuxFoundation
import Foundation

extension CMUXCLI {
    func runMoshTmux(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try runSSH(
            commandArgs: commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride,
            defaultTerminalTransport: .mosh,
            terminalProfile: .defaultTmux
        )
    }

    func buildMoshTerminalStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String?,
        localCommandScript: String?,
        sshFallbackCommand: String,
        sshFallbackLauncherPaths: [String] = []
    ) -> String {
        var invocationOptions = sshCommandOptionsWithoutRemoteCommand(options)
        // Mosh owns terminal allocation; the already-built direct SSH fallback
        // retains the caller's RequestTTY intent.
        invocationOptions.sshOptions = SSHAgentSocketResolver().moshManagementOptions(
            from: invocationOptions.sshOptions
        )
        let capabilityProbeSSHArguments = sshArgumentsOverridingHostRemoteCommand(
            baseSSHArguments(invocationOptions)
        )
        let sessionSSHArguments = sshArgumentsOverridingHostRemoteCommand(
            baseSSHArguments(invocationOptions)
        )
        let remoteCommandArguments: [String]
        let preparationShellScript: String?
        if !options.remoteCommand.arguments.isEmpty {
            // Mosh owns the terminal session; an SSH TTY request only applies
            // if this startup command takes the already-built SSH fallback.
            remoteCommandArguments = options.remoteCommand.arguments
            preparationShellScript = nil
        } else if let remoteBootstrapScript,
                  !remoteBootstrapScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let staging = RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: capabilityProbeSSHArguments,
                destination: options.destination,
                remoteRelayPort: options.remoteRelayPort,
                bootstrapScript: remoteBootstrapScript
            ) else {
                return sshFallbackCommand
            }
            remoteCommandArguments = staging.remoteExecutionCommandArguments
            preparationShellScript = staging.preparationShellScript
        } else {
            remoteCommandArguments = []
            preparationShellScript = nil
        }
        return MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: capabilityProbeSSHArguments,
            sessionSSHArguments: sessionSSHArguments,
            destination: options.destination,
            remoteCommandArguments: remoteCommandArguments,
            remoteRelayPort: options.remoteRelayPort,
            preparationShellScript: preparationShellScript,
            managementReadyShellScript: localCommandScript,
            sshFallbackCommand: sshFallbackCommand,
            sshFallbackLauncherPaths: sshFallbackLauncherPaths,
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
            ),
            remoteBootstrapInstallFailedMessage: String(
                localized: "cli.ssh.mosh.bootstrapInstallFailed",
                defaultValue: "[cmux] Remote bootstrap install failed; continuing over SSH."
            ),
            remoteMoshAddressFallbackMessage: String(
                localized: "cli.ssh.mosh.addressFallback",
                defaultValue: "[cmux] Remote SSH advertised an unusable address; resolving the Mosh address through the SSH connection."
            )
        ).command()
    }

    func buildEternalTerminalStartupCommand(
        options: SSHCommandOptions,
        remoteBootstrapScript: String?,
        localCommandScript: String?,
        sshFallbackCommand: String,
        sshFallbackLauncherPaths: [String] = []
    ) -> String {
        var invocationOptions = sshCommandOptionsWithoutRemoteCommand(options)
        // ET owns terminal allocation; the already-built direct SSH fallback
        // retains the caller's RequestTTY intent.
        invocationOptions.sshOptions = SSHAgentSocketResolver().moshManagementOptions(
            from: invocationOptions.sshOptions
        )
        let managementSSHArguments = sshArgumentsOverridingHostRemoteCommand(
            baseSSHArguments(invocationOptions)
        )
        let remoteCommandArguments: [String]
        let preparationShellScript: String?
        if !options.remoteCommand.arguments.isEmpty {
            remoteCommandArguments = options.remoteCommand.arguments
            preparationShellScript = nil
        } else if let remoteBootstrapScript,
                  !remoteBootstrapScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let staging = RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: managementSSHArguments,
                destination: options.destination,
                remoteRelayPort: options.remoteRelayPort,
                bootstrapScript: remoteBootstrapScript
            ) else {
                return sshFallbackCommand
            }
            remoteCommandArguments = staging.remoteExecutionCommandArguments
            preparationShellScript = staging.preparationShellScript
        } else {
            remoteCommandArguments = []
            preparationShellScript = nil
        }
        return EternalTerminalCommandBuilder(
            capabilityProbeSSHArguments: managementSSHArguments,
            sessionSSHOptions: EternalTerminalCommandBuilder.sessionSSHOptions(
                fromSSHArguments: managementSSHArguments
            ),
            destination: options.destination,
            options: options.eternalTerminalOptions,
            forwardsSSHAgent: EternalTerminalCommandBuilder.forwardsSSHAgent(sshOptions: invocationOptions.sshOptions),
            sshAgentSocketPath: options.agentSocketPath,
            remoteCommandArguments: remoteCommandArguments,
            remoteRelayPort: options.remoteRelayPort,
            preparationShellScript: preparationShellScript,
            managementReadyShellScript: localCommandScript,
            sshFallbackCommand: sshFallbackCommand,
            sshFallbackLauncherPaths: sshFallbackLauncherPaths,
            messages: EternalTerminalCommandBuilder.Messages(
                localMissing: String(
                    localized: "cli.ssh.et.localMissing",
                    defaultValue: "[cmux] Eternal Terminal (et) is not installed locally; continuing over SSH."
                ),
                remoteMissing: String(
                    localized: "cli.ssh.et.remoteMissing",
                    defaultValue: "[cmux] etterminal was not found on the remote host; continuing over SSH. Install Eternal Terminal there or pass --et-terminal-path."
                ),
                remoteProbeFailed: String(
                    localized: "cli.ssh.et.probeFailed",
                    defaultValue: "[cmux] Could not verify remote Eternal Terminal support; continuing over SSH."
                ),
                serverUnreachable: String(
                    localized: "cli.ssh.et.serverUnreachable",
                    defaultValue: "[cmux] etserver is not reachable on the remote host's Eternal Terminal port; continuing over SSH."
                ),
                remoteBootstrapInstallFailed: String(
                    localized: "cli.ssh.et.bootstrapInstallFailed",
                    defaultValue: "[cmux] Remote bootstrap install failed; continuing over SSH."
                ),
                startupRecoveryPrompt: String(
                    localized: "cli.ssh.et.startupRecovery",
                    defaultValue: "[cmux] The terminal transport exited with an error. The remote session or command may already be running. Type ssh and press Return to retry over SSH, which may run it again; any other response closes this terminal."
                ),
                commandUndeliverable: String(
                    localized: "cli.ssh.et.commandUndeliverable",
                    defaultValue: "[cmux] Eternal Terminal cannot deliver this remote command (too long or contains control characters); continuing over SSH."
                )
            )
        ).command()
    }

    /// The `terminal_et_options` object sent with `workspace.remote.configure`.
    func eternalTerminalConfigureParams(_ options: EternalTerminalOptions) -> [String: Any] {
        var params: [String: Any] = [:]
        if let serverPort = options.serverPort { params["port"] = serverPort }
        if let terminalPath = options.terminalPath { params["terminal_path"] = terminalPath }
        if !options.tunnels.isEmpty { params["tunnels"] = options.tunnels }
        if !options.reverseTunnels.isEmpty { params["reverse_tunnels"] = options.reverseTunnels }
        return params
    }
}
