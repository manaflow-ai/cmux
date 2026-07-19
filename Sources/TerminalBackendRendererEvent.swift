import CmuxTerminalBackend
import Foundation

/// Ordered renderer lifecycle information relayed from one trusted daemon session.
enum TerminalBackendRendererEvent: Equatable, Sendable {
    case workerChanged(
        presentationID: UUID,
        change: BackendRendererWorkerChanged
    )
    case presentationReady(
        presentationID: UUID,
        attachment: TerminalBackendRendererAttachment
    )
    case presentationInvalidated(presentationID: UUID)
    case connectionLost(BackendAuthority)
    case reconnected(BackendRendererWorkersResponse)
}
