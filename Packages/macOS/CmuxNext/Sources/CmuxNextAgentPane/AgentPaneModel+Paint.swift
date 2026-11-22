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
