public import AppKit
public import Foundation

/// Coordinates the process-wide identity and lifecycle of a sidebar workspace drag.
///
/// The original identity-only requirements remain the compatibility surface for
/// existing package clients. Session-aware requirements add generation fencing,
/// native-source retention, and coordinated presentation cleanup.
@MainActor
public protocol SidebarWorkspaceDragRegistering: AnyObject {
    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// or `nil` when no sidebar drag is in flight.
    var currentWorkspaceId: UUID? { get }

    /// The token for the current drag, or `nil` when idle.
    var currentSessionId: UUID? { get }

    /// The token most recently issued by this registry, including completed
    /// sessions. Deferred drops use it to reject work from an older generation
    /// after a newer drag has already started and ended.
    var mostRecentSessionId: UUID? { get }

    /// The workspace identity paired with ``mostRecentSessionId``.
    var mostRecentWorkspaceId: UUID? { get }

    /// Record the start of a sidebar drag. Called by the originating window.
    func begin(workspaceId: UUID)

    /// Clear the active drag, but only if `workspaceId` still matches the
    /// in-flight drag, so a stale clear from a superseded drag is a no-op.
    func end(workspaceId: UUID)

    /// Begins a tokenized drag session.
    func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession

    /// Resolves a live session for a matching workspace identity.
    func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession?

    /// Ends the session only when its generation token still matches.
    func end(sessionId: UUID)

    /// Registers a window-local presentation for coordinated cleanup.
    func register(_ state: SidebarDragState)

    /// Starts and retains the AppKit source for a tokenized drag session.
    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage,
        capabilityValue: String
    ) -> Bool

    /// Completes a native drag and clears only its matching residual capability.
    func nativeDraggingSessionDidEnd(sessionId: UUID, capabilityValue: String)
}

/// Compatibility defaults for identity-only registry implementations.
public extension SidebarWorkspaceDragRegistering {
    /// Provides the current generation token for identity-only registries.
    var currentSessionId: UUID? { currentWorkspaceId }

    /// Compatibility registries have no history beyond their current token.
    var mostRecentSessionId: UUID? { currentSessionId }

    /// Compatibility registries expose the current workspace as their latest
    /// identity and fail closed after completion.
    var mostRecentWorkspaceId: UUID? { currentWorkspaceId }

    /// Starts a compatibility session using the workspace id as its token.
    /// - Parameter workspaceId: The workspace represented by the drag.
    /// - Returns: A session value that fences completion callbacks.
    func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        begin(workspaceId: workspaceId)
        return SidebarWorkspaceDragSession(id: workspaceId, workspaceId: workspaceId)
    }

    /// Resolves a compatibility session when its workspace id is current.
    /// - Parameter workspaceId: The workspace identity observed by a drop.
    /// - Returns: A synthetic session, or `nil` when no matching drag exists.
    func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession? {
        guard currentWorkspaceId == workspaceId else { return nil }
        return SidebarWorkspaceDragSession(id: workspaceId, workspaceId: workspaceId)
    }

    /// Ends a compatibility session when its workspace token still matches.
    /// - Parameter sessionId: The token returned by ``beginSession(workspaceId:)``.
    func end(sessionId: UUID) {
        guard currentSessionId == sessionId else { return }
        end(workspaceId: sessionId)
    }

    /// Supplies no participant retention for identity-only registries.
    /// - Parameter state: The window-local presentation to observe.
    func register(_ state: SidebarDragState) {}

    /// Declines native dragging for identity-only registries.
    /// - Returns: Always `false`, because no native source is available.
    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage,
        capabilityValue: String
    ) -> Bool {
        false
    }

    /// Ends the compatibility session after a native completion callback.
    /// - Parameter sessionId: The completed session token.
    func nativeDraggingSessionDidEnd(sessionId: UUID, capabilityValue: String) {
        end(sessionId: sessionId)
    }
}
