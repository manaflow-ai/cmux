import Foundation

/// One-shot started/parked signal for scripting hooks in tests.
actor TestPhaseSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
