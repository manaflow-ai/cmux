/// Ordered provider-lifecycle evidence for one context-pressure episode.
public struct AgentContextPressureLifecycleConfirmation: Equatable, Sendable {
    /// Whether a running-to-idle boundary has confirmed the current episode.
    public private(set) var isConfirmed = false

    private var observedRunning = false

    /// Creates empty confirmation state.
    public init() {}

    /// Records pressure output against the provider lifecycle known at that
    /// callback boundary.
    ///
    /// - Parameters:
    ///   - isNewEpisode: Whether this is the first marker since the last reset.
    ///   - lifecycle: The current authoritative provider lifecycle snapshot.
    public mutating func observePressure(
        isNewEpisode: Bool,
        lifecycle: AgentContextLifecycleState
    ) {
        if isNewEpisode {
            reset()
        }
        if lifecycle == .running {
            isConfirmed = false
            observedRunning = true
        }
    }

    /// Records one ordered provider lifecycle update.
    ///
    /// A repeated or delayed idle update cannot confirm pressure by itself.
    /// The current episode must first observe the provider running.
    ///
    /// - Parameter lifecycle: The effective provider lifecycle after the
    ///   update was applied.
    public mutating func observeLifecycle(_ lifecycle: AgentContextLifecycleState) {
        switch lifecycle {
        case .running:
            isConfirmed = false
            observedRunning = true
        case .idle where observedRunning:
            isConfirmed = true
            observedRunning = false
        case .unknown:
            reset()
        case .needsInput, .idle:
            break
        }
    }

    /// Clears all evidence at a recovery, input, or ownership boundary.
    public mutating func reset() {
        isConfirmed = false
        observedRunning = false
    }
}
