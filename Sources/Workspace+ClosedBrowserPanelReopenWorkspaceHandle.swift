import Bonsplit
import CmuxBrowser
import Foundation

/// `Workspace`'s conformance to the `CmuxBrowser`
/// ``ClosedBrowserPanelReopenWorkspaceHandle`` seam: the per-workspace browser-panel
/// restore and focus-reconciliation operations the package
/// ``ClosedBrowserPanelReopenCoordinator`` drives but cannot own, because
/// `Workspace` is an app-target god type owning the Bonsplit split tree and the
/// WebKit `BrowserPanel` instances.
///
/// ``reopenClosedBrowserPanel(_:)`` is a byte-faithful lift of the former
/// `TabManager.reopenClosedBrowserPanel(_:in:)` three-tier placement walk
/// (original-pane reuse, the fallback split against a remembered anchor, the
/// focused-or-first-pane last resort), with the `in workspace:` parameter dropped
/// because the receiver is now the workspace itself; it maps the created
/// `BrowserPanel?` to its `UUID?` id at this boundary so the package never sees the
/// app-owned panel reference.
///
/// `focusedPanelId` (the workspace's own property), `hasPanel(_:)` (witnessed by
/// the sibling `Workspace+BrowserOpenWorkspaceHandle` conformance), and
/// `focusPanel(_:)` (the bare single-argument focus entry the post-reopen focus
/// enforcement uses, witnessed by the sibling `Workspace+SplitMoveReorderHosting`
/// conformance, which forwards to the full `Workspace.focusPanel` with the exact
/// defaults the legacy `tab.focusPanel(reopenedPanelId)` call relied on) already
/// satisfy the seam's reads/writes. They are declared on `Workspace` in those
/// sibling files and satisfy this protocol from the single implementation, so only
/// ``reopenClosedBrowserPanel(_:)`` is declared here.
extension Workspace: ClosedBrowserPanelReopenWorkspaceHandle {
    // `focusPanel(_:)` is a shared witness with the `SplitMoveReorderHosting`
    // conformance (identical requirement, `func focusPanel(_ panelId: UUID)`); it
    // is declared in `Workspace+SplitMoveReorderHosting.swift` and satisfies this
    // protocol from that single `Workspace` implementation, mirroring how
    // `hasPanel(_:)` is shared with the `BrowserOpenWorkspaceHandle` conformance.

    func reopenClosedBrowserPanel(_ snapshot: ClosedBrowserPanelRestoreSnapshot) -> UUID? {
        if let originalPane = bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserPanel = newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let tabCount = bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, tabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            reorderSurface(panelId: browserPanel.id, toIndex: targetIndex)
            return browserPanel.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorTab = bonsplitController.selectedTab(inPane: anchorPane) ?? bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = panelIdFromSurfaceId(anchorTab.id),
           let browserPanelId = newBrowserSplit(
               from: anchorPanelId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
    }
}
