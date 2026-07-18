import CmuxTerminal
import CmuxTerminalBackend
import CmuxTerminalRenderProtocol
import Foundation

/// Async service seam between a main-actor terminal façade and the trusted daemon session.
protocol TerminalBackendClient: Sendable {
    func rendererEvents() async -> AsyncStream<TerminalBackendRendererEvent>
    func canonicalSnapshots() async throws -> AsyncStream<TopologySnapshot>
    func canonicalTopologyEvents() async throws -> AsyncStream<TerminalBackendTopologyStreamEvent>
    func terminalActivitySnapshots() async -> AsyncStream<BackendTerminalActivitySnapshot>

    func ensureTerminal(
        _ request: TerminalBackendTerminalRequest
    ) async throws -> TerminalBackendTerminalBinding

    func apply(
        _ mutation: TerminalExternalRuntimeMutation,
        requestID: UUID,
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

    func readAccessibilitySnapshot(
        presentationID: UUID,
        expectedContentSequence: UInt64,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalAccessibilitySnapshot

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String

    func activateHyperlink(
        at event: TerminalExternalMouseEvent,
        contentSequence: UInt64,
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalHyperlinkHit

    func detachPresentation(
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding?
    ) async throws

    func activateRenderer(_ activation: TerminalBackendRendererActivation) async throws

    func releaseFrame(_ release: TerminalRenderFrameRelease) async throws
}

/// Connection-aware canonical topology delivery. Unlike the legacy snapshot-only
/// stream, this preserves transaction metadata and explicitly revokes authority
/// while the backend connection is unavailable.
enum TerminalBackendTopologyStreamEvent: Equatable, Sendable {
    case snapshot(TopologySnapshot)
    case delta(TopologyDelta)
    case disconnected(BackendAuthority)
}

extension TerminalBackendClient {
    func activateRenderer(_ activation: TerminalBackendRendererActivation) async throws {
        _ = activation
        throw TerminalBackendClientError.rendererNotReady
    }

    func terminalActivitySnapshots() async -> AsyncStream<BackendTerminalActivitySnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Compatibility adapter for test doubles and older clients. Production's
    /// coordinator overrides this so deltas and disconnects remain first-class.
    func canonicalTopologyEvents() async throws -> AsyncStream<TerminalBackendTopologyStreamEvent> {
        let snapshots = try await canonicalSnapshots()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                for await snapshot in snapshots {
                    guard !Task.isCancelled else { break }
                    continuation.yield(.snapshot(snapshot))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func readAccessibilitySnapshot(
        presentationID: UUID,
        expectedContentSequence: UInt64,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalAccessibilitySnapshot {
        _ = presentationID
        _ = expectedContentSequence
        _ = binding
        throw TerminalBackendClientError.presentationUnavailable
    }

    func activateAccessibilityLink(
        _ link: TerminalAccessibilityLink,
        snapshot: TerminalAccessibilitySnapshot,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> String {
        _ = link
        _ = snapshot
        _ = binding
        throw TerminalBackendClientError.presentationUnavailable
    }

    func activateHyperlink(
        at event: TerminalExternalMouseEvent,
        contentSequence: UInt64,
        presentationID: UUID,
        from binding: TerminalBackendTerminalBinding
    ) async throws -> TerminalExternalHyperlinkHit {
        _ = event
        _ = contentSequence
        _ = presentationID
        _ = binding
        throw TerminalBackendClientError.presentationUnavailable
    }
}
