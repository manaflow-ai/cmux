/// Owns the explicit lifecycle observation state for a process-backed restore binding.
///
/// Observation is bounded: a binding whose restore command never launches, or
/// whose shell never reports a prompt transition, would otherwise stay protected
/// from empty scans on every relaunch. After ``observationWindow`` the binding is
/// treated like any unobserved binding again.
public struct RestoredProcessDetectionObservation: Equatable, Sendable {
    /// Upper bound for a paced restore to spawn its shell and run the queued command.
    public static let observationWindow: Duration = .seconds(300)

    private var armedAt: ContinuousClock.Instant?

    /// Creates a cleared observation policy.
    public init() {
        armedAt = nil
    }

    /// Arms observation until authoritative evidence arrives or the window elapses.
    public mutating func arm(at now: ContinuousClock.Instant = .now) {
        armedAt = now
    }

    /// Returns whether the restore binding remains protected from an empty scan.
    public func preserves(at now: ContinuousClock.Instant = .now) -> Bool {
        guard let armedAt else { return false }
        return armedAt.duration(to: now) < Self.observationWindow
    }

    /// Clears observation after authoritative process or shell evidence.
    public mutating func clear() {
        armedAt = nil
    }
}
