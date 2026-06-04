/// ``MobileShellComposite`` is the connection-side context for its carved-out
/// ``MobileRecoveryCoordinator``: it answers whether recovery can be
/// attempted, whether a live event-stream resync suffices, and performs the
/// actual reconnect. `markMacConnectionReconnecting` and
/// `reconnectActiveMacIfAvailable` are witnessed by the members in the main
/// class body.
extension MobileShellComposite: MobileConnectionRecoveryContext {
    var canAttemptRecovery: Bool {
        remoteClient != nil || connection.pairedMacStore != nil
    }

    var hasLiveRemoteConnection: Bool {
        connectionState == .connected && remoteClient != nil
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    func resyncTerminalOutput(reason: String, restartEventStream: Bool) {
        terminalOutput.resyncTerminalOutput(reason: reason, restartEventStream: restartEventStream)
    }
}
