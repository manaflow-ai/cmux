import Foundation

/// (C) ExternalHover diagnostics — review B5: the SOLE authority for how
/// much of a lifetime's monotonic cumulative `dropped_count` has already
/// been reported, shared between `ExternalHoverWorkService`'s own
/// setter/render-trigger/withdrawal drains and
/// `TerminalSurfaceRuntimeTeardownCoordinator`'s final teardown drain, so
/// neither path ever re-reports a delta the other has already reported.
/// Before this type existed, the teardown path had no access to the
/// actor's own `previousDroppedCountByLifetime` and simply reported the
/// ring's full cumulative count as if it were a fresh delta every time —
/// double-reporting anything the actor had already logged.
///
/// Plain lock-protected state, not actor-isolated: the teardown drain
/// runs from a `nonisolated` context on
/// `TerminalSurfaceRuntimeTeardownCoordinator` with no actor to hop
/// through to reach `ExternalHoverWorkService`, and this must be
/// readable/writable from there without an `await`.
public final class ExternalHoverDroppedCountTracker: @unchecked Sendable {
    private let lock = NSLock()
    internal var previousByLifetime: [RuntimeSurfaceLifetimeID: UInt64] = [:]

    public init() {}

    /// Records `cumulative` as the new baseline for `lifetimeID` and
    /// returns the delta since whatever was last reported for it — by
    /// EITHER caller, since both share this same instance. Zero if
    /// `cumulative` didn't advance since the last report; never negative
    /// (a cumulative value that somehow reads back lower than the last
    /// one seen is treated as a fresh baseline with a zero delta, rather
    /// than underflowing).
    @discardableResult
    public func reportAndComputeDelta(lifetimeID: RuntimeSurfaceLifetimeID, cumulative: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let previous = previousByLifetime[lifetimeID] ?? 0
        previousByLifetime[lifetimeID] = cumulative
        return cumulative > previous ? cumulative - previous : 0
    }

    /// review non-blocking N2 — removes a closed lifetime's baseline so
    /// this dictionary doesn't grow across surface churn for the
    /// lifetime of the process. Safe to call even if the lifetime was
    /// never reported (a no-op).
    public func closeLifetime(_ lifetimeID: RuntimeSurfaceLifetimeID) {
        lock.lock()
        defer { lock.unlock() }
        previousByLifetime.removeValue(forKey: lifetimeID)
    }

}
