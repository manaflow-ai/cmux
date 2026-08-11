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
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async -> Void
    ) {
        self.shims = shims
        self.state = TerminalSurfaceAgentCommandShimLeaseState(
            shims: shims,
            remove: remove
        )
    }

    /// Removes the owned shim directory exactly once.
    public func release() async {
        await state.release()
    }
}
