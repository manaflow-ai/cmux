public import Foundation
public import Bonsplit

/// The workspace-side seam the ``ClosedPanelHistoryCoordinator`` reads and drives
/// the live split tree and panel graph through, so the coordinator can own the
/// recently-closed eligibility/restore decisions without holding the app-target
/// `Workspace`.
///
/// **Why a synchronous read+write protocol and not value snapshots.** Capturing a
/// closed panel and reopening one each run inside a single MainActor turn against
/// the authoritative `BonsplitController` tree and the workspace's live panel
/// graph: the capture reads the closing tab's index and pane neighbors and builds
/// the panel ``SessionPanelSnapshot`` from the live surface; the restore creates a
/// live `TerminalPanel`/`BrowserPanel`, reorders it into place, grows a fallback
/// split, and closes the placeholder. Pushing either through a stream would open a
/// suspension window in which pane/tab mutations could interleave, changing which
/// pane the panel lands in or which placeholder gets closed. The coordinator
/// stays `@MainActor` and calls the host synchronously; the per-window
/// `Workspace` is the single conformer. This mirrors
/// ``WorkspaceSessionRestoreHosting`` and ``SurfaceLifecycleHosting``.
///
/// The live panel/snapshot creation (`createPanel(from:)`, `newTerminalSplit`,
/// `sessionPanelSnapshot`, the warm agent index, the in-memory resume binding)
/// stays app-side behind ``buildClosedPanelSnapshot(panelId:)`` and the restore
/// primitives, because those touch the app-target `Panel`/`TerminalPanel`/
/// `BrowserPanel` types and `RestorableAgentSessionIndex`, which never cross into
/// the package. The coordinator sequences them.
@MainActor
public protocol WorkspaceClosedPanelHistoryHosting<Snapshot>: AnyObject {
    /// The captured panel snapshot value type, owned by the executable target
    /// (`SessionPanelSnapshot`). The seam stays generic over it for the same
    /// reason ``SessionSnapshotWindowInput`` does: the snapshot DTO lives app-side
    /// and never crosses into the package.
    associatedtype Snapshot: Codable & Sendable

    /// The id of the workspace the coordinator is capturing/restoring panels for
    /// (legacy `Workspace.id`), stamped onto each captured entry.
    var closedPanelHistoryWorkspaceId: UUID { get }

    /// Whether closed-panel history capture is currently suppressed (legacy
    /// `Workspace.suppressClosedPanelHistory`), set during bulk layout
    /// reconciliation so transient closes are not recorded.
    var suppressClosedPanelHistory: Bool { get }

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// The panel id owning the given bonsplit surface id, or `nil` (legacy
    /// `Workspace.panelIdFromSurfaceId`).
    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID?

    /// The current split-tree snapshot (legacy
    /// `bonsplitController.treeSnapshot()`), read for the browser-close fallback
    /// plan.
    func closedPanelHistoryTreeSnapshot() -> ExternalTreeNode

    /// Every pane id, unordered (legacy `bonsplitController.allPaneIds`).
    var allBonsplitPaneIds: [PaneID] { get }

    /// The pane's currently selected tab, falling back to its first tab (legacy
    /// `bonsplitController.selectedTab(inPane:) ?? bonsplitController.tabs(inPane:).first`),
    /// used to resolve a fallback split's anchor panel id.
    func selectedOrFirstTab(inPane paneId: PaneID) -> Bonsplit.Tab?

    /// The panel id of the sibling tab a same-pane restore anchors next to,
    /// reproducing the legacy
    /// `sessionRestoreCoordinator.paneAnchorNeighborIndex(forClosedTabIndex:tabCount:)
    /// .flatMap { panelIdFromSurfaceId(paneTabs[$0].id) }` leg. The neighbor
    /// selection rule lives in ``SessionRestoreCoordinator/paneAnchorNeighborIndex(forClosedTabIndex:tabCount:)``,
    /// which the workspace already holds; the surface→panel resolution against the
    /// live tab list stays app-side. Returns `nil` when the closing tab is the
    /// pane's only tab or its neighbor maps to no panel.
    func closedPanelAnchorPanelId(forClosedTabIndex closedTabIndex: Int, inPane paneId: PaneID) -> UUID?

    /// Consumes the close-history eligibility for a closing surface/panel,
    /// returning whether either key was eligible (legacy
    /// `Workspace.consumeCloseHistoryEligibility` → `surfaceRegistry`). Named
    /// `surfaceRegistry…` so it does not collide with the thin `Workspace`
    /// forwarder of the same concept that the close-handling call sites still use.
    func surfaceRegistryConsumeCloseHistoryEligibility(tabId: TabID, panelId: UUID?) -> Bool

    /// Clears the close-history eligibility for a surface and its resolved owning
    /// panel without recording history (legacy
    /// `Workspace.clearCloseHistoryEligibility` → `surfaceRegistry`). The
    /// surface→panel fallback resolution is performed by the host when `panelId`
    /// is `nil`. Named `surfaceRegistry…` for the same non-collision reason.
    func surfaceRegistryClearCloseHistoryEligibility(tabId: TabID, panelId: UUID?)

    /// Pushes a captured entry onto the recently-closed history stack (legacy
    /// `ClosedItemHistoryStore.shared.push(.panel(entry))`). The store is the
    /// app-target composition-root singleton, so the push stays behind the seam;
    /// the host converts the package value to its `ClosedItemHistoryEntry`.
    func pushClosedPanelHistory(_ entry: ClosedPanelHistoryEntry<Snapshot>)

    /// Builds the captured panel snapshot for the panel, reproducing the legacy
    /// `Workspace.closedPanelHistoryEntry` snapshot leg: the warm shared agent
    /// index (falling back to a fresh load), the in-memory effective resume
    /// binding, and `sessionPanelSnapshot(includeScrollback: true, …)`. Returns
    /// `nil` when no snapshot can be built. Stays app-side because it touches the
    /// app-target panel graph and agent index.
    func buildClosedPanelSnapshot(panelId: UUID) -> Snapshot?

    // MARK: - Restore primitives

    /// The pane id owning the panel, or `nil` (legacy
    /// `Workspace.paneId(forPanelId:)`).
    func paneId(forPanelId panelId: UUID) -> PaneID?

    /// The currently focused pane id, falling back to the first pane (legacy
    /// `bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first`).
    var focusedOrFirstPaneId: PaneID? { get }

    /// Whether a live panel with the given id currently exists (legacy
    /// `Workspace.panels[id] != nil`).
    func hasLivePanel(id: UUID) -> Bool

    /// Recreates a live panel from a captured snapshot into the given pane,
    /// returning the new panel id, or `nil` on failure (legacy
    /// `Workspace.createPanel(from:inPane:snapshotWorkspaceId:)` with
    /// `snapshotWorkspaceId: nil`).
    func createPanel(from snapshot: Snapshot, inPane paneId: PaneID) -> UUID?

    /// Reorders the restored surface to the given tab index (legacy
    /// `Workspace.reorderSurface(panelId:toIndex:)`).
    func reorderSurface(panelId: UUID, toIndex index: Int)

    /// Focuses the given pane and selects the surface owning `panelId` within it
    /// (legacy `bonsplitController.focusPane` + `selectTab` on the resolved
    /// surface id). A no-op when the panel maps to no surface.
    func focusPaneSelectingPanel(_ pane: PaneID, panelId: UUID)

    /// Focuses the given panel (legacy `Workspace.focusPanel(_:)`).
    func focusPanel(_ panelId: UUID)

    /// Triggers the restore focus-flash on the given panel (legacy
    /// `Workspace.triggerFocusFlash(panelId:)`).
    func triggerFocusFlash(panelId: UUID)

    /// Grows a new terminal split from the anchor panel for a fallback restore and
    /// returns the placeholder panel id, or `nil` on failure (legacy
    /// `Workspace.newTerminalSplit(from:orientation:insertFirst:focus: false)`,
    /// returning only the placeholder's id).
    func newFallbackTerminalSplit(
        fromPanelId anchorPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> UUID?

    /// Force-closes the given panel (legacy `Workspace.closePanel(_:force: true)`),
    /// used to retire the fallback split placeholder.
    func closePanel(_ panelId: UUID)
}
