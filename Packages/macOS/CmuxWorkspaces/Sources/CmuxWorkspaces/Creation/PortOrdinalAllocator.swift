import Observation

/// Hands out monotonically increasing CMUX_PORT ordinals so each created
/// workspace gets a distinct port range.
///
/// Each window owns its own `TabManager`, but the ordinal counter is shared
/// process-wide so the port ranges never overlap across windows. The legacy
/// code reached one shared counter through a `static var` on `TabManager`;
/// this is a constructor-injected instance instead, with the composition root
/// (`TabManager`) holding one shared default so the process-wide behavior is
/// preserved while the global mutable state is removed.
///
/// `@MainActor` because every caller (workspace creation and session restore)
/// already runs on the main actor; co-locating the counter with its callers
/// keeps the increment a plain synchronous call with no bridging.
@MainActor
@Observable
public final class PortOrdinalAllocator {
    private var nextOrdinal: Int

    /// Creates an allocator whose first handed-out ordinal is `startingAt`
    /// (default `0`, matching the legacy counter's initial value).
    public init(startingAt: Int = 0) {
        self.nextOrdinal = startingAt
    }

    /// Returns the current ordinal and advances the counter by one.
    public func next() -> Int {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        return ordinal
    }
}
