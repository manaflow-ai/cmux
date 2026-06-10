import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CmuxFileWatch
import CmuxGit
import CmuxProcess
import CoreVideo
import Combine
import CoreServices
import Darwin
import OSLog


// MARK: - Closed Item Reopen
extension TabManager {
    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self)
        }

        if ClosedItemHistoryStore.shared.restoreFirstRestorable(using: { entry in
            switch entry {
            case .panel(let panelEntry):
                return restoreClosedPanel(panelEntry)
            case .workspace(let workspaceEntry):
                return restoreClosedWorkspace(workspaceEntry)
            case .window:
                return false
            }
        }) {
            return true
        }

        return false
    }

    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenClosedHistoryItem(id: id, preferredTabManager: self)
        }

        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        let didRestore: Bool
        switch removed.record.entry {
        case .panel(let panelEntry):
            didRestore = restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            didRestore = restoreClosedWorkspace(workspaceEntry)
        case .window:
            didRestore = false
        }

        if !didRestore {
            ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        }
        return didRestore
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else {
            return false
        }

        let preRestoreFocus = currentFocusHistoryEntry
        let panelId = withFocusHistoryRecordingSuppressed {
            workspace.restoreClosedPanel(entry)
        }

        guard let panelId else { return false }
        ClosedItemHistoryStore.shared.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
        withFocusHistoryRecordingSuppressed {
            if selectedTabId != workspace.id {
                selectedTabId = workspace.id
            }
        }
        recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        rememberFocusedSurface(tabId: workspace.id, surfaceId: panelId)
        recordFocusInHistory(workspaceId: workspace.id, panelId: panelId, preservingForwardBranch: true)
        return true
    }

    @discardableResult
    func restoreClosedWorkspace(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        let preRestoreFocus = currentFocusHistoryEntry
        let workspace = addWorkspace(
            title: entry.snapshot.customTitle ?? entry.snapshot.processTitle,
            workingDirectory: entry.snapshot.currentDirectory,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(entry.snapshot)
        guard !entry.snapshot.hasRestorablePanels || !restoredPanelIds.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        guard !workspace.panels.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        // The snapshot may carry a groupId for a group that no longer exists
        // in this TabManager (e.g. the group was dissolved between close and
        // reopen). Drop those stale references so the restored workspace
        // doesn't render as an orphaned indented row under no header.
        if let groupId = workspace.groupId,
           !workspaceGroups.contains(where: { $0.id == groupId }) {
            workspace.groupId = nil
        }
        // When the group DOES still exist, the workspace is about to be
        // reinserted at its old absolute index, which may now sit inside a
        // different group section after intervening reorders. Renormalize
        // so the restored member lands beside its group.
        let needsNormalize = workspace.groupId != nil && !workspaceGroups.isEmpty
        ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
            from: entry.workspaceId,
            to: workspace.id,
            panelIdMap: restoredPanelIds
        )

        if let currentIndex = tabs.firstIndex(where: { $0.id == workspace.id }) {
            let removed = tabs.remove(at: currentIndex)
            let insertIndex = min(max(entry.workspaceIndex, 0), tabs.count)
            tabs.insert(removed, at: insertIndex)
        }
        if needsNormalize {
            normalizeWorkspaceGroupContiguity()
        }

        withFocusHistoryRecordingSuppressed {
            selectedTabId = workspace.id
        }
        recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        if let focusedPanelId = workspace.focusedPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: focusedPanelId)
            workspace.triggerFocusFlash(panelId: focusedPanelId)
            recordFocusInHistory(workspaceId: workspace.id, panelId: focusedPanelId, preservingForwardBranch: true)
        } else {
            recordFocusInHistory(workspaceId: workspace.id, panelId: nil, preservingForwardBranch: true)
        }
        return true
    }

    func enforceReopenedBrowserFocus(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            tabId: tabId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                tabId: tabId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    tabId: tabId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard selectedTabId == tabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[reopenedPanelId] != nil else {
            return
        }

        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)

        guard tab.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = tab.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        tab.focusPanel(reopenedPanelId)
    }

    func reopenClosedBrowserPanel(
        _ snapshot: ClosedBrowserPanelRestoreSnapshot,
        in workspace: Workspace
    ) -> UUID? {
        if let originalPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserPanel = workspace.newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let tabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, tabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            _ = workspace.reorderSurface(panelId: browserPanel.id, toIndex: targetIndex)
            return browserPanel.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorTab = workspace.bonsplitController.selectedTab(inPane: anchorPane) ?? workspace.bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = workspace.panelIdFromSurfaceId(anchorTab.id),
           let browserPanelId = workspace.newBrowserSplit(
               from: anchorPanelId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
    }

}
