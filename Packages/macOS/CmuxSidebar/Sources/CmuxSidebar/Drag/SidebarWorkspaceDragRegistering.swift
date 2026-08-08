public import AppKit
public import Foundation

/// Coordinates the process-wide identity and lifecycle of a sidebar workspace drag.
///
/// The original identity-only requirements remain the compatibility surface for
/// existing package clients. Session-aware requirements have defaults derived
/// from that identity, while ``SidebarWorkspaceDragRegistry`` overrides them to
/// provide generation tokens, native-source retention, and participant cleanup.
@MainActor
public protocol SidebarWorkspaceDragRegistering: AnyObject {
    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// or `nil` when no sidebar drag is in flight.
    var currentWorkspaceId: UUID? { get }

    /// Records the start of a sidebar drag using the compatibility identity API.
    /// - Parameter workspaceId: The workspace whose drag began.
    func begin(workspaceId: UUID)

    /// Clears the compatibility identity when it still matches `workspaceId`.
    /// - Parameter workspaceId: The workspace whose drag ended.
    func end(workspaceId: UUID)

    /// Begins a tokenized drag session.
    /// - Parameter workspaceId: The workspace whose drag began.
    /// - Returns: The session identity shared by source and mirror presentations.
    func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession

    /// Resolves the live session for a matching workspace identity.
    /// - Parameter workspaceId: The workspace identity observed by a destination.
    /// - Returns: The matching live session, or `nil` when the identity is stale.
    func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession?

    /// Ends the session only when its generation token still matches.
    /// - Parameter sessionId: The token returned by ``beginSession(workspaceId:)``.
    func end(sessionId: UUID)

    /// Registers a window-local presentation for coordinated terminal cleanup.
    /// - Parameter state: The presentation state to clear when its session ends.
    func register(_ state: SidebarDragState)

    /// Starts and retains the AppKit source for a tokenized drag session.
    /// - Parameters:
    ///   - sessionId: The token returned by ``beginSession(workspaceId:)``.
    ///   - pasteboardItem: The process-local workspace transfer payload.
    ///   - sourceView: The AppKit view whose window owns the drag session.
    ///   - event: The mouse-down event that initiated drag tracking.
    ///   - draggingFrame: The source-row frame in `sourceView` coordinates.
    ///   - dragImage: A snapshot displayed beneath the drag pointer.
    /// - Returns: `true` when a matching native session started.
    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage
    ) -> Bool
}

/// Default session behavior for compatibility implementations of the original identity-only seam.
public extension SidebarWorkspaceDragRegistering {
    /// Compatibility fallback for clients implementing the original identity-only seam.
    func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession {
        begin(workspaceId: workspaceId)
        return SidebarWorkspaceDragSession(id: workspaceId, workspaceId: workspaceId)
    }

    /// Compatibility fallback that derives a stable token from the workspace identity.
    func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession? {
        guard currentWorkspaceId == workspaceId else { return nil }
        return SidebarWorkspaceDragSession(id: workspaceId, workspaceId: workspaceId)
    }

    /// Compatibility fallback for the identity-derived session token.
    func end(sessionId: UUID) {
        guard currentWorkspaceId == sessionId else { return }
        end(workspaceId: sessionId)
    }

    /// Identity-only registries do not coordinate window-local presentation cleanup.
    func register(_ state: SidebarDragState) {}

    /// Identity-only registries cannot own an AppKit native drag source.
    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage
    ) -> Bool {
        false
    }
}
