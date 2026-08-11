public import CmuxTerminalCore

/// Owns one installed command-shim directory until the canonical terminal exits.
///
/// The lease does not remove the directory during deinitialization because a
/// daemon-owned terminal can outlive its current presentation. The canonical
/// terminal owner must call ``release()`` after terminal teardown.
public final class TerminalSurfaceAgentCommandShimLease: Sendable {
    /// The installed command shims retained by this lease.
    public let shims: TerminalSurfaceAgentCommandShimSet
    private let state: TerminalSurfaceAgentCommandShimLeaseState

    init(
        shims: TerminalSurfaceAgentCommandShimSet,
        removalAttemptLimit: Int,
        removalLane: TerminalSurfaceAgentCommandShimRemovalLane,
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async throws -> Void,
        reportRemovalFailure:
            @escaping @Sendable (TerminalSurfaceAgentCommandShimSet, String) -> Void
    ) {
        self.shims = shims
        self.state = TerminalSurfaceAgentCommandShimLeaseState(
            shims: shims,
            removalAttemptLimit: removalAttemptLimit,
            removalLane: removalLane,
            remove: remove,
            reportRemovalFailure: reportRemovalFailure
        )
    }

    /// Removes the owned shim directory with bounded retries.
    ///
    /// Returns `false` after the final failure so the owner can retain the lease
    /// and request cleanup again later.
    @discardableResult
    public func release() async -> Bool {
        await state.release()
    }
}
