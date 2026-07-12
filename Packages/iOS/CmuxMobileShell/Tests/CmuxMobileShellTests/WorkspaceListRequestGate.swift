import Foundation

actor WorkspaceListRequestGate {
    private var count = 0
    private var holdFirst = false
    private var usesOrdinalTitles = false
    private var firstHeld = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func setHoldFirst(_ hold: Bool) {
        holdFirst = hold
    }

    func setUsesOrdinalTitles(_ usesTitles: Bool) {
        usesOrdinalTitles = usesTitles
    }

    func beforeResponse() async -> String? {
        count += 1
        let readyCountWaiters = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for (_, waiter) in readyCountWaiters { waiter.resume() }
        let ordinal = count
        if ordinal == 1, holdFirst {
            firstHeld = true
            let waiters = reachedWaiters
            reachedWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        guard usesOrdinalTitles else { return nil }
        return ordinal == 1 ? "Stale Workspace" : "Fresh Workspace"
    }

    func waitUntilFirstReached() async {
        if firstHeld { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func waitUntilRequestCount(_ expectedCount: Int) async {
        if count >= expectedCount { return }
        await withCheckedContinuation { countWaiters.append((expectedCount, $0)) }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func requestCount() -> Int { count }
}
