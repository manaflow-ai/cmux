public import Foundation
import AppKit

/// Process-wide coordinator for the workspace currently being dragged in any
/// window's sidebar.
///
/// The coordinator owns the session token, retained native drag source, and
/// weak set of source/mirror presentation states. AppKit's terminal source
/// callback clears the token and all matching window-local state together, so
/// no view callback is the sole owner of process-wide cleanup.
@MainActor
public final class SidebarWorkspaceDragRegistry {
    private(set) var currentSession: SidebarWorkspaceDragSession?
    private var nativeDragSources: [UUID: SidebarWorkspaceDragSessionSource] = [:]
    private var participants: [SidebarWorkspaceDragParticipantReference] = []

    /// Creates an empty registry with no drag in flight.
    public init() {}

    /// The workspace participating in the active process-wide drag, if any.
    public var currentWorkspaceId: UUID? { currentSession?.workspaceId }

    @discardableResult
    func begin(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        endCurrentSession()
        let session = SidebarWorkspaceDragSession(workspaceId: workspaceId)
        currentSession = session
        return session
    }

    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage
    ) -> Bool {
        guard currentSession?.id == sessionId else { return false }

        let source = SidebarWorkspaceDragSessionSource(
            sessionId: sessionId,
            registry: self
        )
        nativeDragSources[sessionId] = source

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(draggingFrame, contents: dragImage)
        sourceView.beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: source
        )
        return true
    }

    func nativeDraggingSessionDidEnd(sessionId: UUID) {
        nativeDragSources[sessionId] = nil
        end(sessionId: sessionId)
    }

    func end(sessionId: UUID) {
        guard currentSession?.id == sessionId else { return }
        endCurrentSession()
    }

    func register(_ state: SidebarDragState) {
        participants.removeAll { $0.state == nil || $0.state === state }
        participants.append(SidebarWorkspaceDragParticipantReference(state: state))
    }

    private func endCurrentSession() {
        guard let session = currentSession else { return }
        currentSession = nil
        let participantsSnapshot = participants
        for participant in participantsSnapshot {
            guard let state = participant.state else { continue }
            state.coordinatorDidEnd(sessionId: session.id)
        }
        participants.removeAll { $0.state == nil }
    }
}
