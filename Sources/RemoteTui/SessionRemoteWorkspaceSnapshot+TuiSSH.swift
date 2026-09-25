import CmuxCore
import CmuxFoundation
import Foundation

extension SessionRemoteWorkspaceSnapshot {
    /// Restore the carrier descriptor without reviving a cmuxd-remote launch script.
    func tuiSSHConfiguration(
        agentSocketPath: String?,
        sshKeepaliveSettings: SSHKeepaliveSettings? = nil
    ) -> WorkspaceRemoteConfiguration? {
        guard sshSessionOwner == "cmux-tui", transport == .ssh, skipDaemonBootstrap != true,
              (terminalTransport ?? .ssh) == .ssh, preserveAfterTerminalExit == true else { return nil }
        let configuredSSHOptions = sshKeepaliveSettings?.appendingMissingOptions(to: WorkspaceRemoteConfiguration.durableSSHOptions(sshOptions))
            ?? WorkspaceRemoteConfiguration.durableSSHOptions(sshOptions)
        var configuration = WorkspaceRemoteConfiguration(
            terminalProfile: terminalProfile ?? .shell, destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port.flatMap { (1...65535).contains($0) ? $0 : nil },
            identityFile: WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile),
            sshOptions: configuredSSHOptions,
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, configuredRemoteCommand: configuredRemoteCommand,
            agentSocketPath: agentSocketPath, preserveAfterTerminalExit: true
        )
        configuration.restoredSSHSession = self
        return configuration
    }
}
