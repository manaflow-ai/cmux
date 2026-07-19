actor BlockingAccountSwitchTokenProvider {
    private var didEnter = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var token = "user-a-token"

    func waitUntilRequested() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func tokenIgnoringCancellation() async throws -> String {
        didEnter = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return token
    }

    func release(with token: String) {
        self.token = token
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
