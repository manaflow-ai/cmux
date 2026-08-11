internal import CmuxTerminalCore

actor TerminalSurfaceAgentCommandShimLeaseState {
    private var shims: TerminalSurfaceAgentCommandShimSet?
    private let remove: @Sendable (TerminalSurfaceAgentCommandShimSet) async -> Void

    init(
        shims: TerminalSurfaceAgentCommandShimSet,
        remove: @escaping @Sendable (TerminalSurfaceAgentCommandShimSet) async -> Void
    ) {
        self.shims = shims
        self.remove = remove
    }

    func release() async {
        guard let shims else { return }
        self.shims = nil
        await remove(shims)
    }
}
