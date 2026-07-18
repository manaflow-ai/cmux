import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalRenderProtocol
import Foundation

/// Async service seam between a main-actor terminal façade and the trusted daemon session.
protocol TerminalBackendClient: Sendable {
    func rendererEvents() async -> AsyncStream<TerminalBackendRendererEvent>
    func canonicalSnapshots() async -> AsyncStream<TopologySnapshot>

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        to binding: TerminalBackendTerminalBinding,
        presentation: TerminalBackendPresentationDescriptor?
    ) async throws -> TerminalBackendMutationOutcome

    func readScreenText(
        _ request: TerminalExternalScreenTextRequest,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String?

    func readSelection(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalSelection?

    func readTerminalUXState(
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalBackendMutationOutcome

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async

    func releaseFrame(_ release: TerminalRenderFrameRelease) async
}
