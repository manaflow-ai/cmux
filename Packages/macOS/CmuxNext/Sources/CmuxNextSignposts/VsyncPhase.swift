/// Where a time placed on the display's vsync grid got that grid: the newest display-link tick a frame
/// scheduler delivered, read without starting a link (`DisplayFrameSample` in CmuxNextWakeups).
///
/// Chrome's presentation feedback separates a measured present from an estimate the same way
/// (`gfx::PresentationFeedback::kVSync` versus a time with no hardware clock, ui/gfx/presentation_feedback.h):
/// a reader keeps the rows of each phase apart.
public nonisolated enum VsyncPhase: String, Sendable, Hashable, CaseIterable {
    /// A display link was running: the grid is the display's current one.
    case running
    /// No link runs, but its last tick is under `DisplayFrameSample.maxPhaseAge` (one second): the period and phase hold.
    case recent
    /// No tick, or only an old one: the time is a guess (the commit plus 1.5 refresh periods).
    case unknown

    /// The phase's number in a ring record (bits 32-39 of `action.presented_estimate`'s `arg0`). Fixed: rings
    /// written by an older build decode with the same numbers; 0 stays "not given".
    public var traceCode: UInt64 {
        switch self {
        case .running: 1
        case .recent: 2
        case .unknown: 3
        }
    }
}

/// The fields of an `action.presented_estimate` event (``SignpostName/actionPresentedEstimate``), handed to the
/// log system unformatted, as ``ActionSignpostMessage`` is.
public nonisolated struct ActionPresentSignpostMessage: Sendable, Hashable {
    /// The action's id (`ActionID.rawValue`).
    public var id: String
    /// The action's interned index (0 when none was interned).
    public var actionIndex: UInt32
    /// The run's start to its estimated present, in milliseconds.
    public var presentMilliseconds: Double
    /// The run's start to its commit, in milliseconds (`action.commit`).
    public var commitMilliseconds: Double
    /// The person's input event's age at the run's start, or -1.
    public var inputAgeMilliseconds: Double
    /// Where the vsync grid of the estimate came from.
    public var phase: VsyncPhase
    /// The estimate, in uptime nanoseconds (`CLOCK_UPTIME_RAW`, the clock of `CACurrentMediaTime`).
    public var estimateUptimeNanos: UInt64

    /// A message for one committed action run.
    public init(id: String, actionIndex: UInt32, presentMilliseconds: Double, commitMilliseconds: Double,
                inputAgeMilliseconds: Double, phase: VsyncPhase, estimateUptimeNanos: UInt64) {
        self.id = id
        self.actionIndex = actionIndex
        self.presentMilliseconds = presentMilliseconds
        self.commitMilliseconds = commitMilliseconds
        self.inputAgeMilliseconds = inputAgeMilliseconds
        self.phase = phase
        self.estimateUptimeNanos = estimateUptimeNanos
    }

    /// The ring record's `arg0`: the action's index in bits 0-31, the phase's code in bits 32-39.
    public var traceArg0: UInt64 {
        UInt64(actionIndex) | phase.traceCode << 32
    }
}
