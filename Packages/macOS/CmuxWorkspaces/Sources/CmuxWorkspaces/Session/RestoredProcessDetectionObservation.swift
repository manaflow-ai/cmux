/// Owns the explicit lifecycle observation state for a process-backed restore binding.
///
/// A restored binding is protected from empty scans while its terminal has not
/// yet spawned, because its restore command cannot have run. Once the runtime
/// spawns, protection lasts ``observationWindow``: a binding whose command never
/// launches, or whose shell never reports a prompt transition, then retires like
/// any unobserved binding instead of surviving every relaunch.
public struct RestoredProcessDetectionObservation: Equatable, Sendable {
    /// Upper bound for a spawned restored shell to run its queued command.
    ///
    /// Measured on the suspending clock so machine sleep does not consume it.
    public static let observationWindow: Duration = .seconds(300)

    private enum Phase: Equatable, Sendable {
        case awaitingRuntimeSpawn
        case runtimeSpawned(at: SuspendingClock.Instant)
    }

    private var phase: Phase?

    /// Creates a cleared observation policy.
    public init() {
        phase = nil
    }

    /// Arms observation until the runtime spawns and evidence arrives or the window elapses.
    public mutating func arm() {
        phase = .awaitingRuntimeSpawn
    }

    /// Starts the observation window once the restored terminal runtime exists.
    ///
    /// - Returns: Whether the observation state changed.
    @discardableResult
    public mutating func recordRuntimeSpawn(at now: SuspendingClock.Instant = .now) -> Bool {
        guard phase == .awaitingRuntimeSpawn else { return false }
        phase = .runtimeSpawned(at: now)
        return true
    }

    /// Returns whether the restore binding remains protected from an empty scan.
    public func preserves(at now: SuspendingClock.Instant = .now) -> Bool {
        switch phase {
        case nil:
            return false
        case .awaitingRuntimeSpawn:
            return true
        case .runtimeSpawned(let spawnedAt):
            return spawnedAt.duration(to: now) < Self.observationWindow
        }
    }

    /// Clears observation after authoritative process or shell evidence.
    public mutating func clear() {
        phase = nil
    }
}
