import CmuxTerminal
import CmuxTerminalRenderProtocol

/// Authenticated worker fence and geometry returned by renderer configuration.
struct TerminalBackendRendererAttachment: Equatable, Sendable {
    let fence: TerminalRenderPresentationFence
    let worker: TerminalRenderWorkerIdentity
    let cellMetrics: TerminalExternalCellMetrics
}
