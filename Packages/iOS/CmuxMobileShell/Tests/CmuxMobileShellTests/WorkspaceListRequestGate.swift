import Foundation

actor WorkspaceListRequestGate {
    private var count = 0
    private var holdFirst = false
    private var firstHeld = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []

    func setHoldFirst(_ hold: Bool) {
        holdFirst = hold
    }

    func beforeResponse() async {
        count += 1
        guard count == 1, holdFirst else { return }
        firstHeld = true
        let waiters = reachedWaiters
        reachedWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilFirstReached() async {
        if firstHeld { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func releaseFirst() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func requestCount() -> Int { count }
}
