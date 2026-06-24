import Bonsplit
import CmuxBrowser
import CmuxPanes
import Foundation

/// `Workspace` is the live host for its `ClosedBrowserRestoreStaging`
/// coordinator. Every member reproduces one read the legacy
/// `Workspace.stageClosedBrowserRestoreSnapshotIfNeeded(for:inPane:)` body
/// performed inline: the close-history suppression flag, the
/// surface-id-to-panel resolution, the browser-panel check, the tab index in the
/// pane, the resolved page url, the browser profile id, the temporary-history-url
/// rejection, and the `browserCloseFallbackPlan` computed off the Bonsplit tree
/// snapshot. The coordinator is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
///
/// The fallback plan is mapped from the `CmuxPanes` `BrowserCloseFallbackPlan`
/// into the package-local ``ClosedBrowserRestoreFallbackPlan`` so `CmuxBrowser`
/// stays free of a `CmuxPanes` dependency.
extension Workspace: ClosedBrowserRestoreStagingHosting {
    var stagingWorkspaceId: UUID { id }

    var stagingSuppressClosedPanelHistory: Bool { suppressClosedPanelHistory }

    func stagingPanelId(forSurfaceId surfaceId: TabID) -> UUID? {
        panelIdFromSurfaceId(surfaceId)
    }

    func stagingIsBrowserPanel(panelId: UUID) -> Bool {
        browserPanel(for: panelId) != nil
    }

    func stagingTabIndex(forSurfaceId surfaceId: TabID, inPane pane: PaneID) -> Int? {
        bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == surfaceId })
    }

    func stagingResolvedURL(panelId: UUID) -> URL? {
        guard let browserPanel = browserPanel(for: panelId) else { return nil }
        return browserPanel.currentURL
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))
    }

    func stagingProfileID(panelId: UUID) -> UUID? {
        browserPanel(for: panelId)?.profileID
    }

    func stagingIsTemporaryHistoryURL(_ url: URL?) -> Bool {
        CmuxDiffViewerURLSchemeHandler.isTemporaryHistoryURL(url)
    }

    func stagingFallbackPlan(forPane pane: PaneID) -> ClosedBrowserRestoreFallbackPlan? {
        guard let plan = bonsplitController.treeSnapshot().browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString
        ) else { return nil }
        return ClosedBrowserRestoreFallbackPlan(
            orientation: plan.orientation,
            insertFirst: plan.insertFirst,
            anchorPaneId: plan.anchorPaneId
        )
    }
}
