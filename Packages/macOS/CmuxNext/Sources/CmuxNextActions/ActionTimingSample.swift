/// One timed action run, as ``ActionBudgetMonitor`` keeps it: from the registry starting the run
/// to the end of the Core Animation commit after it (the `action.commit` interval).
///
/// A value of fixed size: the monitor writes it into a preallocated ring on the main actor.
public nonisolated struct ActionTimingSample: Sendable, Hashable {
    /// How the run's interval ended.
    public enum Outcome: UInt8, Sendable, Hashable {
        /// At the Core Animation commit that ended the run's turn.
        case committed
        /// After the main run loop slept and woke (the commit pass had begun before the run's
        /// boundary was installed): the time includes idle time and is not a commit.
        case missed
        /// The handler ran a nested run loop that waited for the person (a pop-up menu, a modal
        /// panel): the time holds the person's dwell.
        case nested
    }

    /// The run's position among every run the monitor recorded (0 first).
    public var sequence: UInt64
    /// The action.
    public var id: ActionID
    /// Where the run came from.
    public var entrypoint: ActionEntrypoint
    /// `CLOCK_UPTIME_RAW` nanoseconds at the run's start (the watchdog's and `NSEvent`'s clock).
    public var startUptimeNanos: UInt64
    /// Nanoseconds from the run's start to the end of its interval (the commit, for a committed run).
    public var nanos: UInt64
    /// The age in milliseconds of the person's input event at the run's start, or -1.
    public var inputAgeMilliseconds: Double
    /// How the interval ended.
    public var outcome: Outcome

    /// - Parameters:
    ///   - sequence: The run's position among recorded runs.
    ///   - id: The action.
    ///   - entrypoint: Where the run came from.
    ///   - startUptimeNanos: The run's start.
    ///   - nanos: The run's start to its interval's end.
    ///   - inputAgeMilliseconds: The input event's age, or -1.
    ///   - outcome: How the interval ended.
    public init(sequence: UInt64, id: ActionID, entrypoint: ActionEntrypoint, startUptimeNanos: UInt64, nanos: UInt64,
                inputAgeMilliseconds: Double, outcome: Outcome) {
        self.sequence = sequence
        self.id = id
        self.entrypoint = entrypoint
        self.startUptimeNanos = startUptimeNanos
        self.nanos = nanos
        self.inputAgeMilliseconds = inputAgeMilliseconds
        self.outcome = outcome
    }

    /// Perform-to-commit time in milliseconds.
    public var milliseconds: Double { Double(nanos) / 1_000_000 }

    /// Input-to-commit time in milliseconds when the run answers a person's input event (its age
    /// plus ``milliseconds``), else nil.
    public var inputToCommitMilliseconds: Double? {
        inputAgeMilliseconds < 0 ? nil : inputAgeMilliseconds + milliseconds
    }

    /// Whether the run committed later than `budgetNanos` after it started. A missed commit or a
    /// nested loop never counts: neither time is the run's work.
    public func isOver(budgetNanos: UInt64) -> Bool {
        outcome == .committed && nanos > budgetNanos
    }
}
