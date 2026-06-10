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


// MARK: - Unread indicators and tab pinning
extension Workspace {
    func representativePanelIdForWorkspaceManualUnread() -> UUID? {
        if let focusedPanelId, panels[focusedPanelId] != nil {
            return focusedPanelId
        }

        let selectedPanelsByPaneId = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.compactMap { paneId -> (String, UUID)? in
                guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id,
                      let panelId = panelIdFromSurfaceId(tabId),
                      panels[panelId] != nil else {
                    return nil
                }
                return (paneId.id.uuidString, panelId)
            }
        )

        for paneId in SidebarBranchOrdering.orderedPaneIds(tree: bonsplitController.treeSnapshot()) {
            guard let panelId = selectedPanelsByPaneId[paneId] else { continue }
            return panelId
        }

        return sidebarOrderedPanelIds().first
    }

    nonisolated enum RestoredPanelUnreadIndicator: Equatable, Sendable {
        case visualOnly
        case workspaceUnread

        init(contributesToWorkspaceUnread: Bool) {
            self = contributesToWorkspaceUnread ? .workspaceUnread : .visualOnly
        }

        var contributesToWorkspaceUnread: Bool {
            self == .workspaceUnread
        }
    }

    func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        let kind = panels[panelId].map { surfaceKind(for: $0) }
        if let tab = bonsplitController.tab(tabId),
           tab.isPinned == isPinned,
           kind.map({ tab.kind == $0 }) ?? true {
            return
        }
        if let kind {
            bonsplitController.updateTab(tabId, kind: .some(kind), isPinned: isPinned)
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    func hasVisibleNotificationIndicator(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasVisibleNotificationIndicator(forTabId: id, surfaceId: panelId) ?? false
    }

    func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    private func attentionPersistentState() -> WorkspaceAttentionPersistentState {
        let notificationStore = AppDelegate.shared?.notificationStore
        let unreadPanelIDs = Set(
            panels.keys.filter {
                restoredUnreadPanelIds.contains($0) ||
                    (notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: $0) ?? false)
            }
        )
        return WorkspaceAttentionPersistentState(
            unreadPanelIDs: unreadPanelIDs,
            focusedReadPanelID: notificationStore?.focusedReadIndicatorSurfaceId(forTabId: id),
            manualUnreadPanelIDs: manualUnreadPanelIds
        )
    }

    func requestAttentionFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        let decision = WorkspaceAttentionCoordinator.decideFlash(
            targetPanelID: panelId,
            reason: reason,
            persistentState: attentionPersistentState()
        )
        guard decision.isAllowed else { return }
        panels[panelId]?.triggerFlash(reason: reason)
    }

    func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasVisibleNotificationIndicator(panelId: panelId),
            hasPanelUnreadIndicator: manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId),
            isWorkspaceManuallyUnread: notificationStore?.hasManualUnread(forTabId: id) ?? false,
            isWorkspaceManualUnreadRepresentative: representativePanelIdForWorkspaceManualUnread() == panelId
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    func syncUnreadBadgeStateForAllPanels() {
        for panelId in panels.keys {
            syncUnreadBadgeStateForPanel(panelId)
        }
    }

    func syncPanelDerivedWorkspaceUnread() {
        AppDelegate.shared?.notificationStore?.setPanelDerivedUnread(
            !manualUnreadPanelIds.isEmpty ||
                hasWorkspaceContributingRestoredUnreadIndicator,
            forTabId: id
        )
    }

    var hasWorkspaceContributingRestoredUnreadIndicator: Bool {
        restoredUnreadPanelIndicators.values.contains { $0.contributesToWorkspaceUnread }
    }

    func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setPanelCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if trimmed.isEmpty {
            guard previous != nil else { return }
            panelCustomTitles.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else { return }
            panelCustomTitles[panelId] = trimmed
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }
    private var backgroundPrimeTerminalPanels: [TerminalPanel] {
        var seenPanelIds = Set<UUID>()
        return bonsplitController.allPaneIds.compactMap { paneId -> TerminalPanel? in
            guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id ?? bonsplitController.tabs(inPane: paneId).first?.id, let panelId = panelIdFromSurfaceId(tabId), seenPanelIds.insert(panelId).inserted else { return nil }
            return panels[panelId] as? TerminalPanel
        }
    }

    private func hasBackgroundSurfaceStartWork(for panel: TerminalPanel) -> Bool {
        panel.surface.hasDeferredStartupWorkForBackgroundStart() ||
            pendingTerminalInputObserversByPanelId[panel.id]?.isEmpty == false
    }

    private var backgroundPrimeTerminalPanelsNeedingSurfaceStart: [TerminalPanel] {
        backgroundPrimeTerminalPanels.filter { panel in
            panel.surface.surface == nil && hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    func hasBackgroundPrimeTerminalSurfaceStartWork() -> Bool {
        backgroundPrimeTerminalPanels.contains {
            hasBackgroundSurfaceStartWork(for: $0)
        }
    }

    func requestBackgroundPrimeTerminalSurfaceStartIfNeeded() {
        backgroundPrimeTerminalPanelsNeedingSurfaceStart.forEach {
            $0.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    func hasLoadedBackgroundPrimeTerminalSurface() -> Bool {
        backgroundPrimeTerminalPanels.allSatisfy { panel in
            panel.surface.surface != nil || !hasBackgroundSurfaceStartWork(for: panel)
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        tabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalPanel? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let terminalPanel = panels[panelId] as? TerminalPanel else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId &&
            terminalPanel.surface.isViewInWindow &&
            terminalPanel.hostedView.superview != nil

        if isVisibleSelection {
            terminalPanel.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalPanel
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        guard !terminalPanels.isEmpty else { return true }
        return terminalPanels.contains { $0.surface.surface != nil }
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let didClearRestored = restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
        let didInsertManual = manualUnreadPanelIds.insert(panelId).inserted
        guard didInsertManual || didClearRestored else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func preferredUnreadPanelIdForJump() -> UUID? {
        let latestManualPanelId = manualUnreadMarkedAt
            .filter { manualUnreadPanelIds.contains($0.key) && panels[$0.key] != nil }
            .max { $0.value < $1.value }?
            .key
        if let latestManualPanelId {
            return latestManualPanelId
        }
        if let manualPanelId = manualUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return manualPanelId
        }
        if let restoredPanelId = restoredUnreadPanelIds.first(where: { panels[$0] != nil }) {
            return restoredPanelId
        }
        return representativePanelIdForWorkspaceManualUnread()
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        let notificationStore = AppDelegate.shared?.notificationStore
        notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        _ = clearManualUnreadState(panelId: panelId)
        let restoredIndicator = restoredUnreadPanelIndicators[panelId]
        let didClearRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        if didClearRestored,
           restoredIndicator?.contributesToWorkspaceUnread == true,
           !hasWorkspaceContributingRestoredUnreadIndicator {
            _ = notificationStore?.clearRestoredUnreadIndicator(forTabId: id)
        }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearUnreadAfterJump(panelId: UUID?) {
        if let panelId,
           manualUnreadPanelIds.contains(panelId) || restoredUnreadPanelIds.contains(panelId) {
            markPanelRead(panelId)
            return
        }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveManual = clearManualUnreadState(panelId: panelId)
        let didRemoveRestored = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveManual || didRemoveRestored else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    @discardableResult
    func clearAllPanelUnreadIndicatorsForWorkspaceRead() -> Bool {
        let hadLocalUnreadIndicators = !manualUnreadPanelIds.isEmpty || !restoredUnreadPanelIds.isEmpty
        let affectedPanelIds = Set(panels.keys)
            .union(manualUnreadPanelIds)
            .union(restoredUnreadPanelIds)
        guard !affectedPanelIds.isEmpty else { return false }
        manualUnreadPanelIds.removeAll()
        restoredUnreadPanelIndicators.removeAll()
        manualUnreadMarkedAt.removeAll()
        for panelId in affectedPanelIds {
            syncUnreadBadgeStateForPanel(panelId)
        }
        return hadLocalUnreadIndicators
    }

    private func clearManualUnreadState(panelId: UUID) -> Bool {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        return didRemoveUnread
    }

    func restorePanelUnreadIndicator(
        _ panelId: UUID,
        contributesToWorkspaceUnread: Bool = true
    ) {
        guard panels[panelId] != nil else { return }
        let nextIndicator = RestoredPanelUnreadIndicator(
            contributesToWorkspaceUnread: contributesToWorkspaceUnread
        )
        guard restoredUnreadPanelIndicators[panelId] != nextIndicator else { return }
        restoredUnreadPanelIndicators[panelId] = nextIndicator
        syncUnreadBadgeStateForPanel(panelId)
    }

    func clearRestoredUnreadIndicator(panelId: UUID) {
        let didRemoveUnread = clearRestoredUnreadIndicatorState(panelId: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    func hasRestoredUnreadIndicator(panelId: UUID) -> Bool {
        restoredUnreadPanelIds.contains(panelId)
    }

    func restoredUnreadIndicatorContributesToWorkspace(panelId: UUID) -> Bool? {
        restoredUnreadPanelIndicators[panelId]?.contributesToWorkspaceUnread
    }

    private func clearRestoredUnreadIndicatorState(panelId: UUID) -> Bool {
        restoredUnreadPanelIndicators.removeValue(forKey: panelId) != nil
    }

    static func shouldShowUnreadIndicator(
        hasUnreadNotification: Bool,
        hasPanelUnreadIndicator: Bool,
        isWorkspaceManuallyUnread: Bool = false,
        isWorkspaceManualUnreadRepresentative: Bool = false
    ) -> Bool {
        hasUnreadNotification ||
            hasPanelUnreadIndicator ||
            (isWorkspaceManuallyUnread && isWorkspaceManualUnreadRepresentative)
    }

    // MARK: - Title Management

}
