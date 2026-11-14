extension AgentPaneModel {
    /// Runs `body` once the page has drawn its first frame: now if it has.
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
    }

    func markPainted() {
        guard !hasPainted else { return }
        hasPainted = true
        let waiters = paintWaiters
        paintWaiters = []
        for waiter in waiters { waiter() }
    }
}

extension AgentPaneView {
    /// Whether this page shows drawn and takes keys: it is in a window and not hidden, it drew its first frame
    /// (``AgentPaneModel/hasPainted``, so its loading state left) and its handshake ran. The instant-create bench's
    /// `ready_ms` for Cmd-N and Cmd-T.
    public var isShownReady: Bool { window != nil && !isHidden && model.hasPainted && model.hasHandshake }
}
