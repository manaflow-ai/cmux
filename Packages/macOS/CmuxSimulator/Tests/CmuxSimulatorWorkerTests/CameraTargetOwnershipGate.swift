actor CameraTargetOwnershipGate {
    private var bundleIdentifier: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func transfer(bundleIdentifier: String) async {
        self.bundleIdentifier = bundleIdentifier
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async -> String {
        if let bundleIdentifier { return bundleIdentifier }
        await withCheckedContinuation { waiters.append($0) }
        return bundleIdentifier ?? ""
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
