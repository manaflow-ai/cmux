/// The input an action run answers, as its timing reads it (``ActionRunTiming``): the age of the
/// person's input event and the run's entrypoint.
public nonisolated struct ActionRunInput: Sendable, Hashable {
    /// The age in milliseconds of the person's input event the run answers, or -1 (any other
    /// origin, or no event).
    public var ageMilliseconds: Double
    /// Where the run came from.
    public var entrypoint: ActionEntrypoint

    /// - Parameters:
    ///   - ageMilliseconds: The input event's age, or -1.
    ///   - entrypoint: Where the run came from.
    public init(ageMilliseconds: Double, entrypoint: ActionEntrypoint) {
        self.ageMilliseconds = ageMilliseconds
        self.entrypoint = entrypoint
    }
}
