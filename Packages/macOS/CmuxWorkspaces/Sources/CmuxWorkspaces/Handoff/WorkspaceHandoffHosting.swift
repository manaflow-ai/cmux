public import Foundation

/// The window-side seam the ``WorkspaceHandoffCoordinator`` drives: snapshot
/// reads of the window's workspace ordering, selection, pinning, and
/// cycle-hot state, plus the synchronous mutations the mount-reconcile and
/// workspace-handoff state machine performs (portal rendering toggles and the
/// deferred previous-workspace unfocus).
///
/// **Why a synchronous two-way protocol and not an `AsyncStream`.** Every
/// operation here is one MainActor turn that interleaves reads (the ordered
/// workspace ids, the selected id, the pinned/cycle-hot inputs, whether a
/// workspace is ready for immediate handoff) with writes (enable/disable
/// portal rendering on each workspace, complete the deferred unfocus) and is
/// itself re-entered synchronously from SwiftUI `.onChange`/`.onReceive`
/// closures and the selection change. Pushing any leg through a stream would
/// open a suspension window in which user-driven mutations could interleave —
/// an observable change to mount/handoff timing. The coordinator stays
/// `@MainActor` and calls the host synchronously; the per-window `TabManager`
/// is the single implementer. This mirrors the ``FocusedSurfaceHosting`` seam,
/// whose state machine the handoff completion drives into.
///
/// Reads return empty/`nil`/`false` when a workspace is gone, mirroring the
/// legacy optional-chained `tabs.first(where:)` lookups; the portal-render
/// mutation on a gone workspace is a no-op.
@MainActor
public protocol WorkspaceHandoffHosting: AnyObject {
    /// The window's workspace ids in tab order (legacy `tabManager.tabs.map
    /// { $0.id }`). Used both as the mount-plan ordering input and as the set
    /// the portal-rendering reconcile iterates. A method (not a property)
    /// because the per-window `TabManager` already witnesses an identical
    /// `orderedWorkspaceIds()` for the SidebarGit seam; one declaration
    /// satisfies both.
    func orderedWorkspaceIds() -> [UUID]

    /// The window's selected workspace id, if any (legacy
    /// `tabManager.selectedTabId`).
    var selectedWorkspaceId: UUID? { get }

    /// Workspace ids pinned mounted by background-load bookkeeping (legacy
    /// `tabManager.mountedBackgroundWorkspaceLoadIds`).
    var mountedBackgroundWorkspaceLoadIds: Set<UUID> { get }

    /// Workspace ids pinned mounted for DEBUG inspection (legacy
    /// `tabManager.debugPinnedWorkspaceLoadIds`).
    var debugPinnedWorkspaceLoadIds: Set<UUID> { get }

    /// Whether a workspace cycle is in progress (legacy
    /// `tabManager.isWorkspaceCycleHot`), which widens the mount budget to the
    /// handoff pair and warms the selected workspace.
    var isWorkspaceCycleHot: Bool { get }

    /// Enables or disables portal rendering for the workspace (legacy
    /// `workspace.setPortalRenderingEnabled(_:reason:)`), a no-op when the
    /// workspace is gone.
    func setWorkspacePortalRenderingEnabled(workspaceId: UUID, enabled: Bool, reason: String)

    /// Whether the workspace is ready to complete a handoff immediately
    /// (legacy `canCompleteWorkspaceHandoffImmediately(for:)`): true when the
    /// workspace is gone, when its focused panel is a browser panel, or when it
    /// has a loaded terminal surface. Encapsulates the `Workspace` reach so the
    /// coordinator never imports the workspace god type.
    func workspaceIsReadyForImmediateHandoff(workspaceId: UUID) -> Bool

    /// Completes the deferred previous-workspace unfocus (legacy
    /// `tabManager.completePendingWorkspaceUnfocus(reason:)`, which forwards to
    /// ``FocusedSurfaceModel``).
    func completePendingWorkspaceUnfocus(reason: String)

    /// Emits the legacy DEBUG trace for a mount/handoff state transition. The
    /// host owns the `cmuxDebugLog` sink and the workspace-switch snapshot used
    /// to format the line; release builds make this a no-op.
    func logWorkspaceHandoffEvent(_ event: WorkspaceHandoffEvent)
}
