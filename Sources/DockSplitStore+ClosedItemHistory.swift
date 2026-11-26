import AppKit
import Bonsplit
import CmuxPanes
import Foundation

private struct DockClosedPanelFallbackPlan {
    let orientation: SplitOrientation
    let insertFirst: Bool
    let anchorPanelId: UUID?
}

extension DockSplitStore {
    /// Marks a user-requested close without snapshotting live panel state.
    /// Snapshotting happens only after any close confirmation is accepted.
    func markDockCloseHistoryEligible(panelId: UUID) {
        guard let tabId = surfaceId(forPanelId: panelId) else { return }
        closeHistoryEligibleDockTabIds.insert(tabId)
        pendingClosedPanelHistoryEntries.removeValue(forKey: tabId)
    }

    /// Stages one close batch from a single immutable pane/tree snapshot.
    func stageDockClosedPanelHistory(
        tabIds: Set<TabID>,
        inPane paneId: PaneID
    ) {
        let paneTabs = bonsplitController.tabs(inPane: paneId)
        let eligibleTabs = paneTabs.filter { tabIds.contains($0.id) }
        guard !eligibleTabs.isEmpty else { return }

        let eligibleTabIds = Set(eligibleTabs.map(\.id))
        closeHistoryEligibleDockTabIds.formUnion(eligibleTabIds)
        for tabId in eligibleTabIds {
            pendingClosedPanelHistoryEntries.removeValue(forKey: tabId)
        }

        let fallbackPlan = dockClosedPanelFallbackPlan(for: paneId)
        let agentIndex = dockClosedPanelAgentIndex(for: eligibleTabs)
        for (tabIndex, tab) in paneTabs.enumerated()
        where eligibleTabIds.contains(tab.id) {
            pendingClosedPanelHistoryEntries[tab.id] =
                dockClosedPanelHistoryEntry(
                    tabId: tab.id,
                    inPane: paneId,
                    tabIndex: tabIndex,
                    paneTabs: paneTabs,
                    fallbackPlan: fallbackPlan,
                    restorableAgentIndex: agentIndex
                )
        }
    }

    func discardDockClosedPanelHistory(tabId: TabID) {
        closeHistoryEligibleDockTabIds.remove(tabId)
        pendingClosedPanelHistoryEntries.removeValue(forKey: tabId)
    }

    func commitDockClosedPanelHistory(tabId: TabID) {
        let wasEligible =
            closeHistoryEligibleDockTabIds.remove(tabId) != nil
        let entry =
            pendingClosedPanelHistoryEntries.removeValue(forKey: tabId)
        guard wasEligible, let entry else { return }
        closedItemHistoryStore.push(.panel(entry))
    }

    func stageDockClosedPaneHistory(
        _ paneId: PaneID,
        tabIds: Set<TabID>
    ) {
        let paneTabs = bonsplitController.tabs(inPane: paneId)
        let tabs = paneTabs.filter { tabIds.contains($0.id) }
        for tab in tabs {
            closeHistoryEligibleDockTabIds.remove(tab.id)
            pendingClosedPanelHistoryEntries.removeValue(
                forKey: tab.id
            )
        }
        let fallbackPlan = dockClosedPanelFallbackPlan(for: paneId)
        let agentIndex = dockClosedPanelAgentIndex(for: tabs)
        let entries: [ClosedPanelHistoryEntry] =
            paneTabs.enumerated().compactMap { tabIndex, tab in
                guard tabIds.contains(tab.id) else { return nil }
                return dockClosedPanelHistoryEntry(
                    tabId: tab.id,
                    inPane: paneId,
                    tabIndex: tabIndex,
                    paneTabs: paneTabs,
                    fallbackPlan: fallbackPlan,
                    restorableAgentIndex: agentIndex
                )
            }
        if entries.isEmpty {
            pendingClosedPaneHistoryEntries.removeValue(
                forKey: paneId.id
            )
        } else {
            pendingClosedPaneHistoryEntries[paneId.id] = entries
        }
    }

    func discardDockClosedPaneHistory(_ paneId: PaneID) {
        pendingClosedPaneHistoryEntries.removeValue(forKey: paneId.id)
    }

    func commitDockClosedPaneHistory(_ paneId: PaneID) {
        let entries =
            pendingClosedPaneHistoryEntries.removeValue(forKey: paneId.id)
            ?? []
        for entry in entries {
            closedItemHistoryStore.push(.panel(entry))
        }
    }

    @discardableResult
    func reopenMostRecentlyClosedPanel() -> Bool {
        closedItemHistoryStore.restoreFirstRestorable(
            newerThan: nil,
            matching: { entry in
                guard case .panel(let panelEntry) = entry else {
                    return false
                }
                return panelEntry.workspaceId == self.workspaceId
            },
            using: { entry in
                guard case .panel(let panelEntry) = entry,
                      let restoredPanelId =
                        self.restoreDockClosedPanel(panelEntry) else {
                    return false
                }
                self.closedItemHistoryStore.remapPanelAnchorIds(
                    from: panelEntry.snapshot.id,
                    to: restoredPanelId
                )
                return true
            }
        )
    }

    private func dockClosedPanelHistoryEntry(
        tabId: TabID,
        inPane paneId: PaneID,
        tabIndex: Int,
        paneTabs: [Bonsplit.Tab],
        fallbackPlan: DockClosedPanelFallbackPlan?,
        restorableAgentIndex: RestorableAgentSessionIndex?
    ) -> ClosedPanelHistoryEntry? {
        guard let panelId = surfaceIdToPanelId[tabId],
              let snapshot = closedPanelSessionSnapshot(
                  panelId: panelId,
                  restorableAgentIndex: restorableAgentIndex
              ) else {
            return nil
        }

        let paneAnchorPanelId: UUID?
        if tabIndex + 1 < paneTabs.count {
            paneAnchorPanelId =
                surfaceIdToPanelId[paneTabs[tabIndex + 1].id]
        } else if tabIndex > 0 {
            paneAnchorPanelId =
                surfaceIdToPanelId[paneTabs[tabIndex - 1].id]
        } else {
            paneAnchorPanelId = nil
        }

        let sourceTransfer = detachedSurfaceTransfersByPanelId[panelId]
        return ClosedPanelHistoryEntry(
            workspaceId: workspaceId,
            paneId: paneId.id,
            paneAnchorPanelId: paneAnchorPanelId,
            tabIndex: tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: fallbackPlan.map {
                ClosedPanelSplitPlacement(
                    orientation: $0.orientation,
                    insertFirst: $0.insertFirst,
                    anchorPanelId: $0.anchorPanelId
                )
            },
            sourceWorkspaceId: sourceTransfer?.sourceWorkspaceId,
            sourceSnapshotWorkspaceId:
                sourceTransfer?.sessionRestoreWorkspaceId
        )
    }

    /// Resolves at most one agent index for a close batch. A warm shared index
    /// avoids disk work; the cold fallback loads once for the whole batch.
    /// Restore revalidates cached process evidence before relaunching an agent.
    private func dockClosedPanelAgentIndex(
        for tabs: [Bonsplit.Tab]
    ) -> RestorableAgentSessionIndex? {
        let containsTerminal = tabs.contains { tab in
            guard let panelId = surfaceIdToPanelId[tab.id] else {
                return false
            }
            return panels[panelId] is TerminalPanel
        }
        guard containsTerminal else { return nil }
        return SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
    }

    private func restoreDockClosedPanel(
        _ entry: ClosedPanelHistoryEntry
    ) -> UUID? {
        if entry.restoreInOriginalPane,
           let originalPane = bonsplitController.allPaneIds.first(
               where: { $0.id == entry.paneId }
           ) {
            return restoreDockClosedPanel(entry, inPane: originalPane)
        }
        if let paneAnchorPanelId = entry.paneAnchorPanelId,
           let paneId = paneId(forPanelId: paneAnchorPanelId) {
            return restoreDockClosedPanel(entry, inPane: paneId)
        }
        if let restoredPanelId =
            restoreDockClosedPanelInFallbackSplit(entry) {
            return restoredPanelId
        }
        guard let paneId =
            bonsplitController.focusedPaneId
            ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return restoreDockClosedPanel(entry, inPane: paneId)
    }

    private func restoreDockClosedPanel(
        _ entry: ClosedPanelHistoryEntry,
        inPane paneId: PaneID
    ) -> UUID? {
        guard let panelId = restoreClosedPanelSessionSnapshot(
            entry.snapshot,
            inPane: paneId,
            sourceWorkspaceId: entry.sourceWorkspaceId,
            sourceSnapshotWorkspaceId:
                entry.sourceSnapshotWorkspaceId,
            sourceWorkspaceResolver: { sourceWorkspaceId in
                AppDelegate.shared?.workspaceFor(
                    tabId: sourceWorkspaceId
                )
            }
        ) else {
            return nil
        }

        if let tabId = surfaceId(forPanelId: panelId) {
            let maximumIndex = max(
                0,
                bonsplitController.tabs(inPane: paneId).count - 1
            )
            _ = bonsplitController.reorderTab(
                tabId,
                toIndex: min(max(entry.tabIndex, 0), maximumIndex)
            )
            noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
        }
        focusPanelFromDockInteraction(panelId, window: NSApp.keyWindow ?? NSApp.mainWindow)
        triggerFocusFlash(panelId: panelId)
        return panelId
    }

    private func restoreDockClosedPanelInFallbackSplit(
        _ entry: ClosedPanelHistoryEntry
    ) -> UUID? {
        guard let placement = entry.fallbackSplitPlacement,
              let anchorPanelId = placement.anchorPanelId,
              panels[anchorPanelId] != nil,
              let anchorPaneId = paneId(forPanelId: anchorPanelId) else {
            return nil
        }

        let layoutCodec = SessionSplitContainerLayoutCodec(
            controller: bonsplitController
        )
        guard let placeholder = withProgrammaticDockSplit({
            layoutCodec.createRestorePlaceholderSplit(
                inPane: anchorPaneId,
                orientation: placement.orientation,
                insertFirst: placement.insertFirst
            )
        }) else {
            return nil
        }
        defer {
            forceCloseDockTabIds.insert(placeholder.tabId)
            _ = bonsplitController.closeTab(placeholder.tabId)
            forceCloseDockTabIds.remove(placeholder.tabId)
        }
        return restoreDockClosedPanel(entry, inPane: placeholder.paneId)
    }

    private func dockClosedPanelFallbackPlan(
        for paneId: PaneID
    ) -> DockClosedPanelFallbackPlan? {
        let paneIdsById = Dictionary(
            uniqueKeysWithValues:
                bonsplitController.allPaneIds.map { ($0.id, $0) }
        )
        return dockClosedPanelFallbackPlan(
            forPaneId: paneId.id.uuidString,
            in: bonsplitController.treeSnapshot(),
            paneIdsById: paneIdsById
        )
    }

    private func dockClosedPanelFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode,
        paneIdsById: [UUID: PaneID]
    ) -> DockClosedPanelFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let split):
            if split.first.orderedPaneIds.contains(targetPaneId) {
                if let nested = dockClosedPanelFallbackPlan(
                    forPaneId: targetPaneId,
                    in: split.first,
                    paneIdsById: paneIdsById
                ) {
                    return nested
                }
                return DockClosedPanelFallbackPlan(
                    orientation: split.orientation.lowercased() == "vertical"
                        ? .vertical
                        : .horizontal,
                    insertFirst: true,
                    anchorPanelId: firstDockPanelId(
                        in: split.second,
                        paneIdsById: paneIdsById
                    )
                )
            }
            if split.second.orderedPaneIds.contains(targetPaneId) {
                if let nested = dockClosedPanelFallbackPlan(
                    forPaneId: targetPaneId,
                    in: split.second,
                    paneIdsById: paneIdsById
                ) {
                    return nested
                }
                return DockClosedPanelFallbackPlan(
                    orientation: split.orientation.lowercased() == "vertical"
                        ? .vertical
                        : .horizontal,
                    insertFirst: false,
                    anchorPanelId: firstDockPanelId(
                        in: split.first,
                        paneIdsById: paneIdsById
                    )
                )
            }
            return nil
        }
    }

    private func firstDockPanelId(
        in node: ExternalTreeNode,
        paneIdsById: [UUID: PaneID]
    ) -> UUID? {
        for paneIdString in node.orderedPaneIds {
            guard let paneUUID = UUID(uuidString: paneIdString),
                  let paneId = paneIdsById[paneUUID],
                  let tab = bonsplitController.selectedTab(inPane: paneId)
                    ?? bonsplitController.tabs(inPane: paneId).first,
                  let panelId = surfaceIdToPanelId[tab.id] else {
                continue
            }
            return panelId
        }
        return nil
    }
}
