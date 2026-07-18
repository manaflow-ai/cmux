#if canImport(UIKit)
@MainActor
struct LocalScrollbackScrollQueue {
    private var inFlight: LocalScrollbackScrollRequest?
    private var shouldForwardInFlight = false
    private var pending: LocalScrollbackScrollRequest?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    var isIdle: Bool {
        inFlight == nil && pending == nil
    }

    mutating func enqueue(_ request: LocalScrollbackScrollRequest) -> LocalScrollbackScrollRequest? {
        guard inFlight == nil else {
            if var pending {
                pending.append(request)
                self.pending = pending.lines == 0 ? nil : pending
            } else {
                pending = request
            }
            return nil
        }
        inFlight = request
        shouldForwardInFlight = true
        return request
    }

    mutating func completeInFlight() -> (next: LocalScrollbackScrollRequest?, shouldForward: Bool)? {
        guard inFlight != nil else {
            pending = nil
            return nil
        }
        let next = pending
        let shouldForward = shouldForwardInFlight
        inFlight = next
        shouldForwardInFlight = next != nil
        pending = nil
        resumeDrainWaitersIfIdle()
        return (next, shouldForward)
    }

    mutating func suppressInFlightForwardingAndDiscardPending() {
        pending = nil
        if inFlight != nil {
            shouldForwardInFlight = false
        }
        resumeDrainWaitersIfIdle()
    }

    mutating func takeOutstanding() -> LocalScrollbackScrollRequest? {
        var outstanding = shouldForwardInFlight ? inFlight : nil
        if let pending {
            if outstanding == nil {
                outstanding = pending
            } else {
                outstanding?.append(pending)
            }
        }
        inFlight = nil
        shouldForwardInFlight = false
        pending = nil
        if outstanding?.lines == 0 {
            outstanding = nil
        }
        if outstanding == nil {
            resumeDrainWaitersIfIdle()
        }
        return outstanding
    }

    mutating func reset() {
        inFlight = nil
        shouldForwardInFlight = false
        pending = nil
        resumeDrainWaitersIfIdle()
    }

    mutating func registerDrainWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        guard !isIdle else {
            continuation.resume()
            return
        }
        drainWaiters.append(continuation)
    }

    mutating func finishDraining() {
        resumeDrainWaitersIfIdle()
    }

    private mutating func resumeDrainWaitersIfIdle() {
        guard isIdle, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
#endif
