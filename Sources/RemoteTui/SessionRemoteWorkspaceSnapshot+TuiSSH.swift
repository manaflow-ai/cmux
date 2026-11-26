import CmuxCore
import CmuxFoundation
import Foundation

extension SessionRemoteWorkspaceSnapshot {
    /// Restore the carrier descriptor without reviving a cmuxd-remote launch script.
    func tuiSSHConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration? {
        guard sshSessionOwner == "cmux-tui", isPersistentSSHCarrierShape else { return nil }
        var configuration = carrierConfiguration(agentSocketPath: agentSocketPath)
        configuration.restoredSSHSession = self
        return configuration
    }

    /// Adopts a legacy SSH snapshot whose workload lives in a named tmux session.
    /// The runtime carrier drops the retired relay and daemon slot and attaches
    /// only to that exact existing session. Saves retain the original descriptor:
    /// terminal creation does not prove that the tmux client attached successfully.
    /// Legacy shell profiles stay blocked because their shell lived in the old PTY.
    func legacyTmuxSSHConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration? {
        guard sshSessionOwner == nil, isPersistentSSHCarrierShape,
              let terminalProfile, terminalProfile.kind == .tmux,
              terminalProfile.tmuxSessionName != nil else { return nil }
        var configuration = carrierConfiguration(agentSocketPath: agentSocketPath)
        // Keep subsequent restores attach-only until a future explicit process
        // acknowledgment can establish durable ownership safely.
        configuration.restoredSSHSession = self
        return configuration
    }

    private var isPersistentSSHCarrierShape: Bool {
        transport == .ssh && skipDaemonBootstrap != true &&
            (terminalTransport ?? .ssh) == .ssh && preserveAfterTerminalExit == true
    }

    private func carrierConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            terminalProfile: terminalProfile ?? .shell, destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port.flatMap { (1...65535).contains($0) ? $0 : nil },
            identityFile: WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile),
            sshOptions: sshSessionOwner == "cmux-tui"
                ? WorkspaceRemoteConfiguration.restorableCarrierSSHOptions(sshOptions)
                : WorkspaceRemoteConfiguration.durableSSHOptions(sshOptions),
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, configuredRemoteCommand: configuredRemoteCommand,
            agentSocketPath: agentSocketPath,
            // A saved socket that is no longer live must not turn into a
            // permanent explicit disable. Empty saved values still disable
            // inheritance by design.
            agentSocketPathOverrideIsSet: agentSocketPath != nil ||
                (self.agentSocketPathOverrideIsSet == true &&
                 SSHAgentSocketResolver(environment: [:]).normalizedAgentSocketPath(self.agentSocketPath) == nil),
            preserveAfterTerminalExit: true
        )
    }
}
