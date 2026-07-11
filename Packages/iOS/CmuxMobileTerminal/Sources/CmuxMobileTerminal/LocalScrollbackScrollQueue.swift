#if canImport(UIKit)
struct LocalScrollbackScrollQueue: Sendable {
    private var inFlight: LocalScrollbackScrollRequest?
    private var pending: LocalScrollbackScrollRequest?

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
        return request
    }

    mutating func completeInFlight() -> LocalScrollbackScrollRequest? {
        guard inFlight != nil else {
            pending = nil
            return nil
        }
        let next = pending
        inFlight = next
        pending = nil
        return next
    }

    mutating func discardPending() {
        pending = nil
    }

    mutating func takeOutstanding() -> LocalScrollbackScrollRequest? {
        var outstanding = inFlight
        if let pending {
            if outstanding == nil {
                outstanding = pending
            } else {
                outstanding?.append(pending)
            }
        }
        reset()
        guard let outstanding, outstanding.lines != 0 else { return nil }
        return outstanding
    }

    mutating func reset() {
        inFlight = nil
        pending = nil
    }
}
#endif
