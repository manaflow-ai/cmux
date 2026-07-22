extension RemotePTYBridgeServer.Session {
    func forceClosePendingShutdown() {
        // A transport error can mark the session closed while Network is
        // still waiting to finish its graceful output close. Tunnel teardown
        // overrides that pending close so the CLI can attach through the new transport.
        connection.cancel()
        if isAttaching { return }
        notifyCloseOnce()
    }

    func notifyCloseOnce() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}
