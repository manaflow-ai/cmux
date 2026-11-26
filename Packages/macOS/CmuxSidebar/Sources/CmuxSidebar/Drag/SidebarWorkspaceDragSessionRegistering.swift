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

    /// Begins a tokenized session at a proven native pointer boundary.
    ///
    /// Unlike a logical begin, this boundary proves AppKit has left any older
    /// native drag loop, so superseded source holds may be reclaimed.
    func beginNativeSession(workspaceId: UUID) -> SidebarWorkspaceDragSession

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

    /// Reclaims native sources other than the source identified by
    /// `excludingSessionId` after a pointer/native-session boundary.
    ///
    /// Callers must pass the session whose native loop is still being
    /// completed. Requiring the exclusion in the API prevents a pointer
    /// boundary from accidentally releasing a source that is still live.
    func reclaimSupersededNativeSources(excludingSessionId: UUID)
}
