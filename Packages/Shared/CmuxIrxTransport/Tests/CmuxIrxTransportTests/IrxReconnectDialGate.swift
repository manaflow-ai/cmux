import Foundation

/// A native-style dial that stays suspended after its Swift task is cancelled.
actor IrxReconnectDialGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var starts = 0
    private var released = false

    func wait() async {
        starts += 1
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilStarted() async {
        if starts > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}
