import Bonsplit
import CmuxBrowser
import Foundation

private struct DockBrowserCloseFallbackPlan {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPaneId: UUID?
}

extension DockSplitStore {
    func markExplicitBrowserCloseFromTabStrip(
        tabId: TabID,
        source: TabCloseRequestSource
    ) {
        if source == .closeButton {
            tabCloseButtonCloseDockTabIds.insert(tabId)
        }
        markClosedBrowserHistoryEligible(tabId: tabId)
    }

    func markClosedBrowserHistoryEligible(tabId: TabID) {
        guard panel(for: tabId) is BrowserPanel else { return }
        closedBrowserHistoryEligibleDockTabIds.insert(tabId)
    }

    @discardableResult
    func closePanelRecordingBrowserHistory(
        _ panelId: UUID,
        force: Bool = false
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else { return false }
        markClosedBrowserHistoryEligible(tabId: tabId)
        let closed = closePanel(panelId, force: force)
        if !closed, !pendingCloseConfirmDockTabIds.contains(tabId) {
            clearClosedBrowserHistoryState(for: tabId)
        }
        return closed
    }

    func stageClosedBrowserRestoreSnapshotIfEligible(
        for tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        guard closedBrowserHistoryEligibleDockTabIds.contains(tab.id),
              let browserPanel = panel(for: tab.id) as? BrowserPanel,
              browserPanel.shouldPersistSessionSnapshot(),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(
                  where: { $0.id == tab.id }
              ) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = dockBrowserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))
        guard !browserIsTemporaryHistoryURL(resolvedURL) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        pendingClosedBrowserRestoreSnapshots[tab.id] =
            CmuxBrowser.ClosedBrowserPanelRestoreSnapshot(
                workspaceId: workspaceId,
                url: resolvedURL,
                profileID: browserPanel.profileID,
                originalPaneId: pane.id,
                originalTabIndex: tabIndex,
                fallbackSplitOrientation: fallbackPlan?.orientation,
                fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
                fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
            )
    }

    func commitClosedBrowserRestoreSnapshot(for tabId: TabID) {
        let wasEligible = closedBrowserHistoryEligibleDockTabIds.remove(tabId) != nil
        let snapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
        guard wasEligible, let snapshot else { return }
        closedBrowserModel.recordClosedBrowserPanel(snapshot)
    }

    func clearClosedBrowserHistoryState(for tabId: TabID) {
        closedBrowserHistoryEligibleDockTabIds.remove(tabId)
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    func clearPendingClosedBrowserHistoryState() {
        closedBrowserHistoryEligibleDockTabIds.removeAll()
        pendingClosedBrowserRestoreSnapshots.removeAll()
    }

    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        guard isBrowserAvailable() else { return false }
        while let snapshot = closedBrowserModel.popMostRecentlyClosedBrowserPanel() {
            if restoreClosedBrowserPanel(snapshot) != nil {
                return true
            }
        }
        return false
    }

    private func restoreClosedBrowserPanel(
        _ snapshot: CmuxBrowser.ClosedBrowserPanelRestoreSnapshot
    ) -> UUID? {
        if let originalPane = bonsplitController.allPaneIds.first(
            where: { $0.id == snapshot.originalPaneId }
        ), let panelId = newSurface(
            kind: .browser,
            inPane: originalPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        ) {
            if let tabId = surfaceId(forPanelId: panelId) {
                let tabCount = bonsplitController.tabs(inPane: originalPane).count
                let targetIndex = min(
                    max(snapshot.originalTabIndex, 0),
                    max(0, tabCount - 1)
                )
                _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
            }
            return panelId
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = bonsplitController.allPaneIds.first(
               where: { $0.id == fallbackAnchorPaneId }
           ), let anchorTab = bonsplitController.selectedTab(inPane: anchorPane)
               ?? bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = surfaceIdToPanelId[anchorTab.id],
           let panelId = newSplit(
               kind: .browser,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               sourcePanelId: anchorPanelId,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID,
               focus: true
           ) {
            return panelId
        }

        guard let pane = resolvePane(requestedPaneID: nil) else { return nil }
        return newSurface(
            kind: .browser,
            inPane: pane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )
    }

    private func dockBrowserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> DockBrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first,
               firstPane.id == targetPaneId {
                return DockBrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical"
                        ? .vertical
                        : .horizontal,
                    insertFirst: true,
                    anchorPaneId: dockBrowserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: dockBrowserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second,
               secondPane.id == targetPaneId {
                return DockBrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical"
                        ? .vertical
                        : .horizontal,
                    insertFirst: false,
                    anchorPaneId: dockBrowserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: dockBrowserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = dockBrowserCloseFallbackPlan(
                forPaneId: targetPaneId,
                in: splitNode.first
            ) {
                return nested
            }
            return dockBrowserCloseFallbackPlan(
                forPaneId: targetPaneId,
                in: splitNode.second
            )
        }
    }

    private func dockBrowserPaneCenter(
        _ pane: ExternalPaneNode
    ) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func dockBrowserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        dockBrowserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = dockBrowserPaneCenter(lhs)
                let rhsCenter = dockBrowserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2)
                    + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2)
                    + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        return bestPane.flatMap { UUID(uuidString: $0.id) }
    }

    private func dockBrowserCollectPaneNodes(
        node: ExternalTreeNode,
        into output: inout [ExternalPaneNode]
    ) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            dockBrowserCollectPaneNodes(node: splitNode.first, into: &output)
            dockBrowserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }
}
