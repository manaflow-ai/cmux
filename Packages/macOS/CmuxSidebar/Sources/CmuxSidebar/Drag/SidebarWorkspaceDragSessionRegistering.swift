public import AppKit
public import Foundation

/// Session-aware extension of the compatibility workspace-drag registry.
///
/// Implementations own the generation token, native source retention, and
/// presentation participants. Keeping these requirements separate means an
/// identity-only client can continue conforming to
/// ``SidebarWorkspaceDragRegistering`` without inheriting defaults that cannot
/// preserve a completed native session.
@MainActor
public protocol SidebarWorkspaceDragSessionRegistering: SidebarWorkspaceDragRegistering {
    /// The token for the current drag, or `nil` when idle.
    var currentSessionId: UUID? { get }

    /// The most recently issued token, including completed sessions.
    var mostRecentSessionId: UUID? { get }

    /// Workspace paired with ``mostRecentSessionId``.
    var mostRecentWorkspaceId: UUID? { get }

    /// Begins a tokenized drag session.
    func beginSession(workspaceId: UUID) -> SidebarWorkspaceDragSession

    /// Resolves a live session for a matching workspace identity.
    func session(matching workspaceId: UUID) -> SidebarWorkspaceDragSession?

    /// Ends only the session whose generation token still matches.
    func end(sessionId: UUID)

    /// Registers a window-local presentation for coordinated cleanup.
    func register(_ state: SidebarDragState)

    /// Starts and retains an AppKit source for a tokenized session.
    func beginNativeDragging(
        sessionId: UUID,
        pasteboardItem: NSPasteboardItem,
        sourceView: NSView,
        event: NSEvent,
        draggingFrame: NSRect,
        dragImage: NSImage,
        capabilityValue: String
    ) -> Bool

    /// Completes a native drag and clears only its matching capability.
    func nativeDraggingSessionDidEnd(sessionId: UUID, capabilityValue: String)
}
