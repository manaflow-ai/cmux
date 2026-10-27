/// The input an action run answers, as its timing reads it (``ActionRunTiming``): the age of the
/// person's input event, the run's entrypoint and the caller's flow.
public nonisolated struct ActionRunInput: Sendable, Hashable {
    /// The age in milliseconds of the person's input event the run answers, or -1 (any other
    /// origin, or no event).
    public var ageMilliseconds: Double
    /// Where the run came from.
    public var entrypoint: ActionEntrypoint
    /// The flow id a control-socket caller sent (``ActionInvocation/flow``), or 0: the run's `action.commit`
    /// ends that flow in the trace.
    public var flow: UInt64

    /// - Parameters:
    ///   - ageMilliseconds: The input event's age, or -1.
    ///   - entrypoint: Where the run came from.
    ///   - flow: The caller's flow id, or 0.
    public init(ageMilliseconds: Double, entrypoint: ActionEntrypoint, flow: UInt64 = 0) {
        self.ageMilliseconds = ageMilliseconds
        self.entrypoint = entrypoint
        self.flow = flow
    }
}
