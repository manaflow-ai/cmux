/// The action a timed run is of (``ActionRunTiming/time(_:_:input:_:)``): its id, for the
/// signposts, and its index interned by the timing when the action was bound
/// (``ActionRunTiming/intern(_:)``), for the per-action budget's ring.
public nonisolated struct ActionRunKey: Sendable, Hashable {
    /// The action.
    public var id: ActionID
    /// Its interned index (0 when the timing interns nothing).
    public var index: UInt32

    /// - Parameters:
    ///   - id: The action.
    ///   - index: Its interned index.
    public init(id: ActionID, index: UInt32) {
        self.id = id
        self.index = index
    }
}
