#if DEBUG || CMUX_BENCH_HOOKS
/// An action that ran in the turn a violation was found in (``InvariantTrigger/actions``): its id, its origin and
/// its run number in this registry. Noting one builds no string: both are the action's own raw values.
public struct InvariantActionCause: Hashable, Sendable, Codable {
    public let id: String
    public let origin: String
    /// The registry's count of noted actions when this one ran (1 first).
    public let index: UInt64

    public init(id: String, origin: String, index: UInt64) {
        self.id = id
        self.origin = origin
        self.index = index
    }
}
#endif
