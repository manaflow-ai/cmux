#if DEBUG
public import Foundation

// MARK: - DEBUG-only test accessors

extension TerminalSurfaceRuntimeTeardownCoordinator {
    /// Test support: native frees still queued or in flight. A test that
    /// drops a live TerminalSurface instead of releasing it leaves its free —
    /// and the surface's io threads — racing whatever runs next in the same
    /// host; suites that create surfaces assert this drained back to their
    /// baseline after teardown.
    public var debugPendingTeardownCount: Int {
        pendingReasonsById.count
    }

    /// Test support: the native frees still queued or in flight, keyed by
    /// teardown id (the owning surface id for close/deinit frees) with the
    /// teardown reason, so a leak check can name what is still pending.
    public var debugPendingTeardownReasonsById: [UUID: String] {
        pendingReasonsById
    }
}
#endif
