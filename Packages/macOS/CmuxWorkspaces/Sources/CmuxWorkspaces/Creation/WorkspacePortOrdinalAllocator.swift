/// Process-wide monotonic allocator for `CMUX_PORT` ordinals.
///
/// Each window owns its own `TabManager`, but a single allocator instance is
/// shared across every window so the port ranges those ordinals seed never
/// overlap. ``next()`` returns the current value and then advances the counter,
/// exactly the legacy `let ordinal = Self.nextPortOrdinal; Self.nextPortOrdinal += 1`
/// against the former process-wide `static var nextPortOrdinal`.
///
/// **Why `@MainActor`.** Every caller (the per-window workspace creation and
/// session-restore paths on `TabManager`) already runs on the main actor, so
/// co-locating the counter there keeps each allocation a synchronous
/// read-then-increment with no bridging, byte-faithful to the legacy static-var
/// access. The state machine lives where its callers live.
///
/// **Why an instance, not a static.** The legacy counter was a process-wide
/// `static var`. De-singletonizing it makes the counter a real injectable type:
/// the composition point (`TabManager`) holds one shared default instance for
/// process-wide behavior, while tests can inject their own to isolate ordinals.
@MainActor
public final class WorkspacePortOrdinalAllocator {
    private var nextOrdinal: Int

    /// Creates an allocator whose first ``next()`` returns `startOrdinal`
    /// (legacy initial value `0`).
    public init(startOrdinal: Int = 0) {
        self.nextOrdinal = startOrdinal
    }

    /// Returns the current ordinal, then advances the counter by one.
    public func next() -> Int {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        return ordinal
    }
}
