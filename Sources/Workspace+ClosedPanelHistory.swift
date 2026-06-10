import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Closed panel history
extension Workspace {
    func closedPanelHistoryEntry(panelId: UUID, tabId: TabID, pane: PaneID) -> ClosedPanelHistoryEntry? {
        guard !suppressClosedPanelHistory else { return nil }
        guard let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tabId }) else {
            return nil
        }
        let paneTabs = bonsplitController.tabs(inPane: pane)
        let paneAnchorPanelId: UUID? = {
            if tabIndex + 1 < paneTabs.count {
                return panelIdFromSurfaceId(paneTabs[tabIndex + 1].id)
            }
            if tabIndex > 0 {
                return panelIdFromSurfaceId(paneTabs[tabIndex - 1].id)
            }
            return nil
        }()
        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let fallbackAnchorPanelId = fallbackPlan?.anchorPaneId.flatMap { anchorPaneId -> UUID? in
            guard let anchorPane = bonsplitController.allPaneIds.first(where: { $0.id == anchorPaneId }),
                  let anchorTab = bonsplitController.selectedTab(inPane: anchorPane)
                    ?? bonsplitController.tabs(inPane: anchorPane).first else {
                return nil
            }
            return panelIdFromSurfaceId(anchorTab.id)
        }
        let fallbackSplitPlacement = fallbackPlan.map {
            ClosedPanelSplitPlacement(
                orientation: $0.orientation,
                insertFirst: $0.insertFirst,
                anchorPanelId: fallbackAnchorPanelId
            )
        }
        // Prefer the warm cached agent index over a synchronous
        // `RestorableAgentSessionIndex.load()` (sysctl-per-record + disk, ~350ms-1.8s on
        // machines with large agent history) so closing a tab does not freeze the main
        // thread. Fall back to a fresh load only when the cache has not loaded yet (the
        // brief window after launch before the first refresh completes; the cache is
        // prewarmed at launch so this is rare). A cached entry at most one refresh stale
        // is acceptable here because restore prefers the always-fresh in-memory
        // resumeBinding and only consults this agent snapshot when no binding exists, so
        // cmux-launched agents reopen correctly regardless of cache freshness.
        let agentIndex = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        let restorableAgent = agentIndex.snapshot(workspaceId: id, panelId: panelId)
        guard let snapshot = sessionPanelSnapshot(
            panelId: panelId,
            includeScrollback: true,
            restorableAgent: restorableAgent,
            resumeBinding: effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
        ) else {
            return nil
        }
        return ClosedPanelHistoryEntry(
            workspaceId: id,
            paneId: pane.id,
            paneAnchorPanelId: paneAnchorPanelId,
            tabIndex: tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: fallbackSplitPlacement
        )
    }

    func consumeCloseHistoryEligibility(tabId: TabID, panelId: UUID?) -> Bool {
        let eligibleByTab = closeHistoryEligibleTabIds.remove(tabId) != nil
        let eligibleByPanel = panelId.map { closeHistoryEligiblePanelIds.remove($0) != nil } ?? false
        return eligibleByTab || eligibleByPanel
    }

    func clearCloseHistoryEligibility(tabId: TabID, panelId: UUID? = nil) {
        closeHistoryEligibleTabIds.remove(tabId)
        let resolvedPanelId = panelId ?? panelIdFromSurfaceId(tabId)
        if let resolvedPanelId {
            closeHistoryEligiblePanelIds.remove(resolvedPanelId)
        }
    }

    @discardableResult
    func pushClosedPanelHistoryIfEligible(for tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard !suppressClosedPanelHistory else { return false }
        guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
        guard consumeCloseHistoryEligibility(tabId: tab.id, panelId: panelId) else { return false }
        guard let entry = closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane) else {
            return false
        }
        ClosedItemHistoryStore.shared.push(.panel(entry))
        return true
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        if entry.restoreInOriginalPane,
           let originalPane = bonsplitController.allPaneIds.first(where: { $0.id == entry.paneId }) {
            return restoreClosedPanel(entry, inPane: originalPane)
        }
        if let paneAnchorPanelId = entry.paneAnchorPanelId,
           let pane = paneId(forPanelId: paneAnchorPanelId) {
            return restoreClosedPanel(entry, inPane: pane)
        }
        if let splitPanelId = restoreClosedPanelInFallbackSplit(entry) {
            triggerFocusFlash(panelId: splitPanelId)
            return splitPanelId
        }
        guard let pane = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return restoreClosedPanel(entry, inPane: pane)
    }

    @discardableResult
    private func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry, inPane pane: PaneID) -> UUID? {
        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil
        ) else { return nil }

        let maxIndex = max(0, bonsplitController.tabs(inPane: pane).count - 1)
        _ = reorderSurface(panelId: panelId, toIndex: min(max(entry.tabIndex, 0), maxIndex))
        if let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.focusPane(pane)
            bonsplitController.selectTab(tabId)
        }
        focusPanel(panelId)
        triggerFocusFlash(panelId: panelId)
        return panelId
    }

    @discardableResult
    private func restoreClosedPanelInFallbackSplit(_ entry: ClosedPanelHistoryEntry) -> UUID? {
        guard let placement = entry.fallbackSplitPlacement,
              let anchorPanelId = placement.anchorPanelId,
              panels[anchorPanelId] != nil else {
            return nil
        }

        guard let placeholderPanel = newTerminalSplit(
            from: anchorPanelId,
            orientation: placement.orientation,
            insertFirst: placement.insertFirst,
            focus: false
        ) else {
            return nil
        }
        guard let pane = paneId(forPanelId: placeholderPanel.id) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        guard let panelId = createPanel(
            from: entry.snapshot,
            inPane: pane,
            snapshotWorkspaceId: nil
        ) else {
            _ = closePanel(placeholderPanel.id, force: true)
            return nil
        }

        _ = closePanel(placeholderPanel.id, force: true)
        guard panels[panelId] != nil else {
            return nil
        }
        focusPanel(panelId)
        return panelId
    }

    func markExplicitClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
        closeHistoryEligibleTabIds.insert(surfaceId)
        if let panelId = panelIdFromSurfaceId(surfaceId) {
            closeHistoryEligiblePanelIds.insert(panelId)
        }
    }

    func markCloseHistoryEligible(panelId: UUID) {
        closeHistoryEligiblePanelIds.insert(panelId)
        if let surfaceId = surfaceIdFromPanelId(panelId) {
            closeHistoryEligibleTabIds.insert(surfaceId)
        }
    }

    @discardableResult
    func requestCloseTabRecordingHistory(_ tabId: TabID, force: Bool) -> Bool {
        let panelId = panelIdFromSurfaceId(tabId)
        if let panelId {
            markCloseHistoryEligible(panelId: panelId)
        }

        let closed = requestCloseTab(tabId, force: force)
        return closed
    }

    func withClosedPanelHistorySuppressed(_ body: () -> Void) {
        let previous = suppressClosedPanelHistory
        suppressClosedPanelHistory = true
        defer { suppressClosedPanelHistory = previous }
        body()
    }

    func markTabCloseButtonClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
        tabCloseButtonCloseTabIds.insert(surfaceId)
    }

}
