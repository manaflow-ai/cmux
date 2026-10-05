/// Reduced lifecycle state of one agent session on one surface.
public struct AgentSessionLifecycleState: Sendable, Equatable {
    /// The session's current phase.
    public var phase: AgentLifecyclePhase
    /// Whether the session has ended (ended sessions no longer contribute to
    /// the surface's combined phase).
    public var ended: Bool
    /// Sequence of the newest activity event; duplicate and older activity
    /// assertions cannot overwrite it. Original transition times are retained
    /// while consuming the journal in its authoritative sequence order.
    public var lastSequence: Int64
    /// Producer timestamp of the newest applied event (ms since Unix epoch).
    public var lastOccurredAtMs: Int64
    /// Exact session activity, separate from the legacy phase.
    public var activity: AgentSessionActivity
    /// Structured native reason for the activity.
    public var reason: AgentRuntimeReason?
    /// Mode observed independently of the activity watermark.
    public var mode: AgentExecutionMode
    /// Sequence of the newest mode event; mode-only events do not advance lastSequence.
    public var modeSequence: Int64
    /// Original activity evidence timestamp, nil without an activity assertion.
    public var activityObservedAtMs: Int64?
    /// Original semantic activity transition timestamp.
    public var transitionedAtMs: Int64?
    /// Original independent mode evidence timestamp.
    public var modeObservedAtMs: Int64?
    /// Explicit process generation supplied by the newest activity evidence, if known.
    public var processGeneration: UInt64?
    /// Explicit process generation supplied by the newest mode evidence, if known.
    public var modeProcessGeneration: UInt64?

    /// Creates a session state.
    ///
    /// - Parameters:
    ///   - phase: The session's current phase.
    ///   - ended: Whether the session has ended.
    ///   - lastSequence: Sequence of the newest applied event.
    ///   - lastOccurredAtMs: Producer timestamp of the newest applied event.
    ///   - activity: Rich activity, unknown without an assertion.
    ///   - reason: Structured native reason.
    ///   - mode: Independent native mode, unknown by default.
    ///   - modeSequence: Newest independent mode-event sequence.
    ///   - activityObservedAtMs: Original activity evidence timestamp.
    ///   - transitionedAtMs: Original activity-transition timestamp.
    ///   - modeObservedAtMs: Original mode evidence timestamp.
    ///   - processGeneration: Exact activity process generation, when declared.
    ///   - modeProcessGeneration: Exact mode process generation, when declared.
    public init(
        phase: AgentLifecyclePhase,
        ended: Bool,
        lastSequence: Int64,
        lastOccurredAtMs: Int64,
        activity: AgentSessionActivity = .unknown,
        reason: AgentRuntimeReason? = nil,
        mode: AgentExecutionMode = .unknown,
        modeSequence: Int64 = 0,
        activityObservedAtMs: Int64? = nil,
        transitionedAtMs: Int64? = nil,
        modeObservedAtMs: Int64? = nil,
        processGeneration: UInt64? = nil,
        modeProcessGeneration: UInt64? = nil
    ) {
        self.phase = phase
        self.ended = ended
        self.lastSequence = lastSequence
        self.lastOccurredAtMs = lastOccurredAtMs
        self.activity = activity
        self.reason = reason
        self.mode = mode
        self.modeSequence = modeSequence
        self.activityObservedAtMs = activityObservedAtMs
        self.transitionedAtMs = transitionedAtMs
        self.modeObservedAtMs = modeObservedAtMs
        self.processGeneration = processGeneration
        self.modeProcessGeneration = modeProcessGeneration
    }
}
