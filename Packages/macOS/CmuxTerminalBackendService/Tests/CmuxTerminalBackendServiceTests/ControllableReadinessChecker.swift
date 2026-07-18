import CmuxTerminalBackendService

actor ControllableReadinessChecker: BackendServiceReadinessChecking {
    private let readiness: BackendServiceReadiness
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<BackendServiceReadiness, any Error>?

    init(readiness: BackendServiceReadiness) {
        self.readiness = readiness
    }

    func checkReadiness(
        trustedPair _: BackendServiceInstalledPair
    ) async throws -> BackendServiceReadiness {
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func succeed() {
        completion?.resume(returning: readiness)
        completion = nil
    }
}
