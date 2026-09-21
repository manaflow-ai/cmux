/// Owns the bounded observation window for a process-backed restore binding.
public struct RestoredProcessDetectionObservation: Equatable, Sendable {
    private let interval: Double
    private var deadlineUptime: Double?

    /// Creates an observation policy with a fixed, non-extending interval.
    /// - Parameter interval: Maximum time to preserve a restored binding while detection is absent.
    public init(interval: Double) {
        self.interval = interval
        deadlineUptime = nil
    }

    /// Starts the observation window at the supplied monotonic time.
    /// - Parameter nowUptime: Monotonic clock value used as the window origin.
    public mutating func arm(nowUptime: Double) {
        deadlineUptime = nowUptime + interval
    }

    /// Returns whether the observation is still active at the supplied monotonic time.
    /// - Parameter nowUptime: Monotonic clock value used for the check.
    public func preserves(nowUptime: Double) -> Bool {
        deadlineUptime.map { nowUptime < $0 } == true
    }

    /// Ends the observation window after authoritative process or shell evidence.
    public mutating func clear() {
        deadlineUptime = nil
    }
}
