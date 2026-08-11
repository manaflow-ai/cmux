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
        pendingRequestsById.count
    }

    /// Test support: whether both close slots are active and new ownership is
    /// fenced until one worker returns.
    public var debugCloseTeardownDegraded: Bool {
        runtimeOwnershipAdmission.debugCloseTeardownDegraded
    }

    /// Test support: both close workers exceeded their watchdog deadlines.
    public nonisolated var debugCloseTeardownAllStalled: Bool {
        runtimeOwnershipAdmission.debugCloseTeardownAllStalled
    }

    /// Test support: live plus retained native surfaces charged to admission.
    public nonisolated var debugRuntimeSurfaceOwnerCount: Int {
        runtimeOwnershipAdmission.debugOwnerCount
    }
}
#endif
