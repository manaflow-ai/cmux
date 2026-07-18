import CmuxTerminal
import CmuxTerminalRenderProtocol
import Foundation

/// Authenticated worker fence and geometry returned by renderer configuration.
struct TerminalBackendRendererAttachment: Equatable, Sendable {
    let fence: TerminalRenderPresentationFence
    let worker: TerminalRenderWorkerIdentity
    let cellMetrics: TerminalExternalCellMetrics
}

/// Exact receiver fence that Swift must install before acknowledging an epoch.
struct TerminalBackendRendererActivation: Equatable, Sendable {
    let presentationID: UUID
    let fence: TerminalRenderPresentationFence
    let worker: TerminalRenderWorkerIdentity
}
