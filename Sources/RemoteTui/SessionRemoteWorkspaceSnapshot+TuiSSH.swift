import CmuxCore
import Foundation

extension SessionRemoteWorkspaceSnapshot {
    /// Restore the carrier descriptor without reviving a cmuxd-remote launch script.
    func tuiSSHConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration? {
        guard sshSessionOwner == "cmux-tui", isPersistentSSHCarrierShape else { return nil }
        var configuration = carrierConfiguration(agentSocketPath: agentSocketPath)
        configuration.restoredSSHSession = self
        return configuration
    }

    /// Adopt a pre-cmux-tui persistent SSH snapshot whose terminal ran a named
    /// tmux session. Its workload lives in the remote tmux server, not in the
    /// retired cmuxd-remote PTY, and the tmux profile's `new-session -A -s <name>`
    /// reattaches that same session, so cmux-tui can own it without starting a
    /// replacement workload. The retired relay and daemon slot are dropped; the
    /// next save records cmux-tui ownership. Shell-profile legacy snapshots stay
    /// blocked because their shell only existed inside the daemon PTY.
    func legacyTmuxSSHConfiguration(agentSocketPath: String?) -> WorkspaceRemoteConfiguration? {
        guard sshSessionOwner == nil, isPersistentSSHCarrierShape,
              let terminalProfile, terminalProfile.kind == .tmux,
              terminalProfile.tmuxSessionName != nil else { return nil }
        return carrierConfiguration(agentSocketPath: agentSocketPath)
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
            sshOptions: WorkspaceRemoteConfiguration.durableSSHOptions(sshOptions),
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil, localSocketPath: nil,
            terminalStartupCommand: nil, configuredRemoteCommand: configuredRemoteCommand,
            agentSocketPath: agentSocketPath, preserveAfterTerminalExit: true
        )
    }
}
