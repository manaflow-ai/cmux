public enum TerminalRenderRequestDecision: Equatable, Sendable {
    case enqueue(generation: UInt64, replacedStale: Bool)
    case coalesced
}

public enum TerminalRenderCompletionDecision: Equatable, Sendable {
    case ignoredStaleCompletion
    case idle
    case enqueueCoalesced
}

public struct TerminalRenderFlightState: Equatable, Sendable {
    public private(set) var isInFlight = false
    public private(set) var needsCoalescedRender = false
    public private(set) var generation: UInt64 = 0
    public private(set) var startedAt: Double?

    public init() {}

    public func isStale(now: Double, timeout: Double) -> Bool {
        guard isInFlight, let startedAt else { return false }
        return now - startedAt >= timeout
    }

    public mutating func request(
        now: Double,
        staleTimeout: Double
    ) -> TerminalRenderRequestDecision {
        if isInFlight {
            if isStale(now: now, timeout: staleTimeout) {
                generation &+= 1
                startedAt = now
                needsCoalescedRender = false
                return .enqueue(generation: generation, replacedStale: true)
            }
            needsCoalescedRender = true
            return .coalesced
        }

        isInFlight = true
        needsCoalescedRender = false
        generation &+= 1
        startedAt = now
        return .enqueue(generation: generation, replacedStale: false)
    }

    public mutating func complete(generation completedGeneration: UInt64) -> TerminalRenderCompletionDecision {
        guard isInFlight, completedGeneration == generation else {
            return .ignoredStaleCompletion
        }

        isInFlight = false
        startedAt = nil
        if needsCoalescedRender {
            needsCoalescedRender = false
            return .enqueueCoalesced
        }
        return .idle
    }

    public mutating func reset() {
        isInFlight = false
        needsCoalescedRender = false
        startedAt = nil
        generation &+= 1
    }
}
