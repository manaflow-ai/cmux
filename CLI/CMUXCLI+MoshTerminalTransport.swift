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
        sshFallbackCommand: String
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
}
