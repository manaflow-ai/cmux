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
        let capabilityProbeSSHArguments = sshArgumentsOverridingHostRemoteCommand(
            baseSSHArguments(options)
        )
        let sessionSSHArguments = sshArgumentsOverridingHostRemoteCommand(
            baseSSHArguments(options, localCommandScript: localCommandScript)
        )
        let remoteCommandArguments: [String]
        if !options.extraArguments.isEmpty {
            remoteCommandArguments = options.extraArguments
        } else if let remoteBootstrapScript,
                  !remoteBootstrapScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remoteCommandArguments = [
                "/bin/sh",
                "-c",
                encodedRemoteBootstrapCommand(
                    remoteBootstrapScript,
                    remoteRelayPort: options.remoteRelayPort
                ),
            ]
        } else {
            remoteCommandArguments = []
        }
        return MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: capabilityProbeSSHArguments,
            sessionSSHArguments: sessionSSHArguments,
            destination: options.destination,
            remoteCommandArguments: remoteCommandArguments,
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
            )
        ).command()
    }
}
