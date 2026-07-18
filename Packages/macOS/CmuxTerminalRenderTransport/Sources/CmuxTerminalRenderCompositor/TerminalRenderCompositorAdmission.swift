public import CmuxTerminalRenderProtocol

/// Defense-in-depth metadata admission at the final visible layer boundary.
///
/// The Mach receiver performs the same checks before importing an IOSurface.
/// Repeating them here prevents a caller from accidentally routing an
/// authenticated frame into another terminal's compositor view.
public struct TerminalRenderCompositorAdmission: Equatable, Sendable {
    /// Exact daemon, worker, terminal, presentation, size, and color contract.
    public private(set) var fence: TerminalRenderPresentationFence

    private var acceptance = TerminalRenderFrameAcceptance()

    /// Creates empty latest-frame state for one presentation generation.
    public init(fence: TerminalRenderPresentationFence) {
        self.fence = fence
    }

    /// Replaces the complete presentation contract and clears sequence state.
    public mutating func reset(fence: TerminalRenderPresentationFence) {
        self.fence = fence
        acceptance = TerminalRenderFrameAcceptance()
    }

    /// Accepts the next exact, monotonic frame or returns its rejection reason.
    public mutating func accept(
        _ metadata: TerminalRenderFrameMetadata
    ) -> TerminalRenderFrameRejection? {
        acceptance.accept(metadata, against: fence)
    }
}
