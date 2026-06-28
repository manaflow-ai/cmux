public import Foundation

/// Read/mutate seam the package-side ``SidebarTabDropDelegate`` (in `CmuxSidebarUI`)
/// drives a sidebar workspace reorder drop through, so the delegate never imports
/// the app-target `TabManager` or `AppDelegate`.
///
/// The delegate keys entirely on `UUID` workspace ids and plain value types; this
/// host hides the live state behind those ids. The app target supplies an adapter
/// that forwards the *destination* window queries/mutations to the hovered
/// window's `TabManager`, and the *source* / cross-window routing operations to
/// `AppDelegate.shared.tabManagerFor(tabId:)` / `moveWorkspaceToWindow(...)`. A
/// drop is either an intra-window reorder (all `destination*` reads) or a
/// cross-window move (the `source*` reads plus ``moveWorkspaceToWindow(workspaceId:windowId:atIndex:focus:)``).
@MainActor
public protocol SidebarTabReorderHosting: AnyObject {
    /// The hovered (destination) window's workspace ids in sidebar order (legacy
    /// `tabManager.tabs.map(\.id)`).
    var destinationTabIds: [UUID] { get }

    /// The destination window's currently selected workspace id, if any (legacy
    /// `tabManager.selectedTabId`).
    var destinationSelectedTabId: UUID? { get }

    /// Whether the destination window has any workspace groups, deciding whether
    /// a cross-window indicator reasons in top-level rows (legacy
    /// `!tabManager.workspaceGroups.isEmpty`).
    var destinationHasWorkspaceGroups: Bool { get }

    /// The group id a destination workspace row belongs to, if grouped (legacy
    /// `tabManager.tabs.first { $0.id == tabId }?.groupId`).
    func destinationGroupId(forTab tabId: UUID) -> UUID?

    /// The anchor workspace id of a destination group (legacy
    /// `tabManager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId`).
    func destinationGroupAnchor(forGroup groupId: UUID) -> UUID?

    /// Destination reorder run for a dragged/target pair (legacy
    /// `tabManager.sidebarReorderWorkspaceIds(...)`).
    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> [UUID]

    /// Pinned subset of the destination reorder run (legacy
    /// `tabManager.sidebarReorderPinnedWorkspaceIds(...)`).
    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> Set<UUID>

    /// Whether the destination reorder reasons in top-level rows for this
    /// dragged/target pair (legacy `tabManager.sidebarReorderUsesTopLevelRows(...)`).
    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool

    /// Legal insertion-index range for the destination reorder (legacy
    /// `tabManager.sidebarReorderLegalInsertionRange(...)`).
    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> ClosedRange<Int>?

    /// Commits an intra-window reorder (legacy
    /// `tabManager.reorderSidebarWorkspace(...)`). Returns whether the order
    /// actually changed.
    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool,
        usesTopLevelRows: Bool
    ) -> Bool

    /// Whether the dragged workspace is a group *anchor* in its source window
    /// (legacy `AppDelegate.shared?.tabManagerFor(tabId:)?.workspaceGroups
    /// .contains { $0.anchorWorkspaceId == draggedTabId }`). `false` when no
    /// source window resolves.
    func isGroupAnchorInSourceWindow(_ draggedTabId: UUID) -> Bool

    /// Whether a foreign (other-window) workspace is pinned in its source window
    /// (legacy `AppDelegate.shared?.tabManagerFor(tabId:)?.tabs.first { $0.id == id }?.isPinned`).
    func foreignTabIsPinned(_ id: UUID) -> Bool

    /// The destination window's id (legacy `AppDelegate.shared?.windowId(for: tabManager)`).
    func destinationWindowId() -> UUID?

    /// Whether a source window resolves for the dragged workspace (legacy
    /// `AppDelegate.shared?.tabManagerFor(tabId:) != nil`).
    func sourceWindowExists(forTab draggedTabId: UUID) -> Bool

    /// The source window's multi-selection (legacy
    /// `sourceManager.sidebarSelectedWorkspaceIds`).
    func sourceSelectedWorkspaceIds(forTab draggedTabId: UUID) -> Set<UUID>

    /// Source-ordered workspace ids matching `selection` (legacy
    /// `sourceManager.tabs.filter { selection.contains($0.id) }.map(\.id)`).
    func sourceWorkspaceIds(forTab draggedTabId: UUID, matching selection: Set<UUID>) -> [UUID]

    /// The source window's group anchor ids (legacy
    /// `Set(sourceManager.workspaceGroups.map(\.anchorWorkspaceId))`).
    func sourceGroupAnchorIds(forTab draggedTabId: UUID) -> Set<UUID>

    /// Whether a source workspace is pinned (legacy
    /// `sourceManager.tabs.first { $0.id == workspaceId }?.isPinned`).
    func sourceTabIsPinned(forTab draggedTabId: UUID, workspaceId: UUID) -> Bool

    /// Moves a workspace into the destination window at an optional index (legacy
    /// `AppDelegate.shared?.moveWorkspaceToWindow(...)`). Returns whether the move
    /// succeeded.
    @discardableResult
    func moveWorkspaceToWindow(
        workspaceId: UUID,
        windowId: UUID,
        atIndex: Int?,
        focus: Bool
    ) -> Bool
}
