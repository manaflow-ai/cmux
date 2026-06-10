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


// MARK: - Browser Surfaces
extension TabManager {
    func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.recentlyClosedBrowsers.push(snapshot)
        }
    }

    func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
    }

    /// Create a new browser panel in a split
    func newBrowserSplit(
        tabId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    /// Get a browser panel by ID
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a split-right layout.
    @discardableResult
    func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return nil }
        if selectedTabId != tabId {
            selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserPanel = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.panels[focusedPanelId] != nil {
                    return focusedPanelId
                }
                if let rememberedPanelId = lastFocusedPanelByTab[tabId],
                   workspace.panels[rememberedPanelId] != nil {
                    return rememberedPanelId
                }
                if let orderedPanelId = workspace.sidebarOrderedPanelIds().first(where: { workspace.panels[$0] != nil }) {
                    return orderedPanelId
                }
                return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            }()

            if let splitSourcePanelId,
               let browserPanel = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }
        }

        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let browserPanel = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
        return browserPanel.id
    }

    /// Open a browser in the currently focused pane (as a new surface)
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let tabId = selectedTabId else { return nil }
        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: false,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Reopen the most recently closed browser panel (Cmd+Shift+T).
    /// No-op when no browser panel restore snapshot is available.
    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        if reopenMostRecentlyClosedItem() {
            return true
        }

        return reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    @discardableResult
    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }

        while let snapshot = recentlyClosedBrowsers.pop() {
            // The legacy stack must restore into the workspace that originally owned the
            // browser. If that workspace is gone, the snapshot is stale and we drop it
            // instead of barging into whatever workspace happens to be selected now
            // (which surfaced yesterday's browser inside today's unrelated workspaces).
            guard let targetWorkspace = tabs.first(where: { $0.id == snapshot.workspaceId }) else {
                continue
            }
            let preReopenFocusedPanelId = focusedPanelId(for: targetWorkspace.id)

            if selectedTabId != targetWorkspace.id {
                selectWorkspaceId(
                    targetWorkspace.id,
                    notificationDismissalContext: .explicitWorkspaceResume
                )
            }

            if let reopenedPanelId = reopenClosedBrowserPanel(snapshot, in: targetWorkspace) {
                enforceReopenedBrowserFocus(
                    tabId: targetWorkspace.id,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    func clearRecentlyClosedBrowserPanelHistory() {
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        recentlyClosedBrowsers.mostRecentClosedAt
    }

}
