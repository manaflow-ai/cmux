public import Foundation

/// Read/write seam for the process-wide identity of the workspace currently
/// being sidebar-dragged in any window.
///
/// A sidebar drag is a single, process-global event: at most one workspace is
/// being dragged at a time. The originating window records it here synchronously
/// at drag start and clears it when that drag ends. A *destination* window, which
/// has no local dragged id because the drag began elsewhere, reads this to
/// resolve the dragged workspace for a cross-window move.
///
/// This is deliberately not sourced from `NSPasteboard(name: .drag)`: SwiftUI's
/// `.onDrag` registers the payload through an `NSItemProvider` whose data
/// representation is delivered asynchronously, so a synchronous pasteboard read
/// inside a `DropDelegate` can race and return `nil`. A plain in-process value,
/// set synchronously on the main actor, has no such materialization race.
@MainActor
public protocol SidebarWorkspaceDragRegistering: AnyObject {
    /// The workspace currently being sidebar-dragged anywhere in the process,
    /// or `nil` when no sidebar drag is in flight.
    var currentWorkspaceId: UUID? { get }

    /// Record the start of a sidebar drag. Called by the originating window.
    func begin(workspaceId: UUID)

    /// Clear the active drag, but only if `workspaceId` still matches the
    /// in-flight drag, so a stale clear from a superseded drag is a no-op.
    func end(workspaceId: UUID)
}

/// Process-wide registry of the workspace currently being dragged in any
/// window's sidebar.
///
/// One instance is constructed at the app composition root and injected into
/// every ``SidebarDragState`` (and read by the sidebar's drop delegate) so all
/// windows agree on the single in-flight drag without a shared global.
@MainActor
public final class SidebarWorkspaceDragRegistry: SidebarWorkspaceDragRegistering {
    private var activeWorkspaceId: UUID?

    /// Creates an empty registry with no drag in flight.
    public init() {}

    public var currentWorkspaceId: UUID? { activeWorkspaceId }

    public func begin(workspaceId: UUID) {
        activeWorkspaceId = workspaceId
    }

    public func end(workspaceId: UUID) {
        if activeWorkspaceId == workspaceId {
            activeWorkspaceId = nil
        }
    }
}
