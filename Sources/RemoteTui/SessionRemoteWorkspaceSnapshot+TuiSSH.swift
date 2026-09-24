import CmuxCore
import Foundation

extension SessionRemoteWorkspaceSnapshot {
    /// Restore the carrier descriptor without reviving a cmuxd-remote launch script.
    func tuiSSHConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration? {
        guard transport == .ssh, skipDaemonBootstrap != true,
              (terminalTransport ?? .ssh) == .ssh, preserveAfterTerminalExit == true else { return nil }
        return WorkspaceRemoteConfiguration(
            terminalProfile: terminalProfile ?? .shell, destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port.flatMap { (1...65535).contains($0) ? $0 : nil },
            identityFile: WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile),
            sshOptions: WorkspaceRemoteConfiguration.durableSSHOptions(sshOptions),
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, configuredRemoteCommand: configuredRemoteCommand,
            agentSocketPath: agentSocketPath, preserveAfterTerminalExit: true
        )
    }
}
