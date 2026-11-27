/// One run as ``ActionBudgetMonitor``'s ring stores it: fixed size, no reference (the action is
/// its interned index, never its id string), so writing a slot retains and allocates nothing.
nonisolated struct ActionRunSlot {
    /// The action's interned index (``ActionBudgetMonitor/intern(_:)``; 0 for none).
    var index: UInt32
    var entrypoint: ActionEntrypoint
    var outcome: ActionTimingSample.Outcome
    /// The person's input event's age in milliseconds at the run's start, or -1.
    var inputAgeMilliseconds: Float
    /// `CLOCK_UPTIME_RAW` nanoseconds at the run's start.
    var startUptimeNanos: UInt64
    /// The run's start to its interval's end, in nanoseconds.
    var nanos: UInt64

    static let empty = ActionRunSlot(index: 0, entrypoint: .unattributed, outcome: .committed, inputAgeMilliseconds: -1,
                                     startUptimeNanos: 0, nanos: 0)
}
