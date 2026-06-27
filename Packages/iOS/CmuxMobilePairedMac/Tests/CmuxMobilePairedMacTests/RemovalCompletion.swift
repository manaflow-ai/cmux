actor RemovalCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        finished = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
