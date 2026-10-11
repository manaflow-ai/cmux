/// Generation fence and bounded retry budget shared by the hosted UI and local recovery.
/// Time is supplied by the caller so stability is deterministic in tests.
@_spi(CmuxHostTransport) public struct CMUXSidebarHostRecovery {
    /// Current mounted host generation; every replacement advances it.
    public private(set) var generation: UInt64 = 0
    /// Automatic attempts consumed since the last stable connection.
    public private(set) var attempts = 0
    /// True while one retry is scheduled for the current generation.
    public private(set) var retryPending = false
    private var readyAt: Double?

    /// Creates an inactive host with an unused retry budget.
    public init() {}

    /// Fences the previous host before any transport is torn down.
    /// - Parameter resetBudget: True for explicit recovery or provider selection.
    /// - Returns: The new generation to capture in every callback.
    @discardableResult public mutating func begin(resetBudget: Bool = false) -> UInt64 {
        generation &+= 1
        retryPending = false
        readyAt = nil
        if resetBudget { attempts = 0 }
        return generation
    }

    /// Checks whether a callback belongs to the mounted host.
    /// - Parameter candidate: The generation captured when the host was mounted.
    /// - Returns: Whether its callbacks may mutate current state.
    public func accepts(_ candidate: UInt64) -> Bool { candidate == generation }

    /// Reserves one of three delays after a current transient failure.
    /// - Parameters:
    ///   - candidate: Generation reporting the failure.
    ///   - now: Monotonic time in seconds; thirty stable seconds reset the budget.
    /// - Returns: Delay in seconds, or nil for a stale, pending or exhausted attempt.
    public mutating func retryDelay(for candidate: UInt64, now: Double) -> Double? {
        guard accepts(candidate), !retryPending else { return nil }
        if let readyAt, now - readyAt >= 30 { attempts = 0 }
        readyAt = nil
        let delays = [0.5, 2.0, 5.0]
        guard attempts < delays.count else { return nil }
        let delay = delays[attempts]
        attempts += 1
        retryPending = true
        return delay
    }

    /// Starts measuring stability after the extension acknowledges a snapshot.
    /// - Parameters:
    ///   - candidate: Generation acknowledging the snapshot.
    ///   - now: Monotonic time in seconds.
    public mutating func ready(for candidate: UInt64, now: Double) {
        guard accepts(candidate) else { return }
        retryPending = false
        if readyAt == nil { readyAt = now }
    }
}
