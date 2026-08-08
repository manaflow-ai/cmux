public import Foundation
public import AppKit

/// Process-wide coordinator for the workspace currently being dragged in any
/// window's sidebar.
///
/// The coordinator owns the session token, retained native drag source, and
/// weak set of source/mirror presentation states. AppKit's terminal source
/// callback clears the token and all matching window-local state together, so
/// no view callback is the sole owner of process-wide cleanup.
@MainActor
public final class SidebarWorkspaceDragRegistry: SidebarWorkspaceDragRegistering {
    private(set) var currentSession: SidebarWorkspaceDragSession?
    private var nativeDragSources: [UUID: SidebarWorkspaceDragSessionSource] = [:]
    private var participants: [SidebarWorkspaceDragParticipantReference] = []

    /// Creates an empty registry with no drag in flight.
    public init() {}

    /// The workspace participating in the active process-wide drag, if any.
    public var currentWorkspaceId: UUID? { currentSession?.workspaceId }

    /// Begins a drag through the source-compatible identity API.
    /// - Parameter workspaceId: The workspace whose drag began.
    public func begin(workspaceId: UUID) {
        _ = beginSession(workspaceId: workspaceId)
    }

    /// Clears a drag through the source-compatible identity API.
    /// - Parameter workspaceId: The workspace whose drag ended.
    public func end(workspaceId: UUID) {
        guard currentWorkspaceId == workspaceId else { return }
        endCurrentSession()
    }

    /// Begins a tokenized session, superseding any prior workspace drag.
    /// - Parameter workspaceId: The workspace whose drag began.
    /// - Returns: The new generation-tokenized session.
    public func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        endCurrentSession()
        let session = SidebarWorkspaceDragSession(workspaceId: workspaceId)
        currentSession = session
        return session
    }

    /// Resolves the live tokenized session for a matching workspace.
    /// - Parameter workspaceId: The workspace identity observed by a destination.
    /// - Returns: The matching session, or `nil` for stale pasteboard identity.
    public func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession? {
        guard currentSession?.workspaceId == workspaceId else { return nil }
        return currentSession
    }

    /// Starts and retains the AppKit source for a matching tokenized session.
    public func beginNativeDragging(
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

    /// Ends only the session whose generation token still matches.
    /// - Parameter sessionId: The token returned by ``beginSession(workspaceId:)``.
    public func end(sessionId: UUID) {
        guard currentSession?.id == sessionId else { return }
        endCurrentSession()
    }

    /// Registers a window-local presentation for coordinated terminal cleanup.
    /// - Parameter state: The state to clear when its matching session ends.
    public func register(_ state: SidebarDragState) {
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
