import Foundation

actor SharedLiveAgentIndexProcessMetadataBoundary {
    private var outcome: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        if let outcome {
            return outcome
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    nonisolated func resolve(captured: Bool) {
        // The synchronous process loader cannot await an actor. This bounded hop
        // only resumes already-owned continuations and performs no physical work.
        Task { await resolveOnActor(captured: captured) }
    }

    private func resolveOnActor(captured: Bool) {
        guard outcome == nil else { return }
        outcome = captured
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: captured)
        }
    }
}
