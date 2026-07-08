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
