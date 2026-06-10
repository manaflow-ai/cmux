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


// MARK: - Surface move, reorder, detach, attach
extension Workspace {
    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func moveSurfaceToAdjacentPane(panelId: UUID, direction: NavigationDirection) -> Bool {
        guard panels[panelId] != nil,
              let sourcePaneId = paneId(forPanelId: panelId),
              let targetPaneId = bonsplitController.adjacentPane(to: sourcePaneId, direction: direction) else {
            return false
        }
        return moveSurface(panelId: panelId, toPane: targetPaneId, focus: true)
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if focus, let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard let sourcePanel = panels[panelId] else { return nil }
        let sourcePaneId = paneId(forPanelId: panelId)
        let shouldSkipControlMasterCleanupAfterDetach =
            activeRemoteTerminalSurfaceIds.contains(panelId)
            && activeRemoteTerminalSurfaceIds.count == 1
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        activeDetachCloseTransactions += 1
        defer { activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1) }
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
#if DEBUG
            cmuxDebugLog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        var detached = pendingDetachedSurfaces.removeValue(forKey: tabId)
        if shouldSkipControlMasterCleanupAfterDetach, let detachedTransfer = detached, detachedTransfer.isRemoteTerminal {
            skipControlMasterCleanupAfterDetachedRemoteTransfer = true
            if detachedTransfer.remoteCleanupConfiguration == nil {
                detached = detachedTransfer.withRemoteCleanupConfiguration(remoteConfiguration)
            }
        }
        publishCmuxSurfaceClosed(panelId, paneId: sourcePaneId, panel: sourcePanel, origin: detached == nil ? "detach_lost" : "detach")
#if DEBUG
        cmuxDebugLog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true,
        focusIntent: PanelFocusIntent? = nil
    ) -> UUID? {
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        cmuxDebugLog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let ttyName = detached.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[detached.panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: detached.panelId)
        }
        syncRemotePortScanTTYs()
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }
        if let restoredUnreadIndicator = detached.restoredUnreadIndicator {
            restoredUnreadPanelIndicators[detached.panelId] = restoredUnreadIndicator
        } else {
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
        }
        let detachedBrowserMuted = (detached.panel as? BrowserPanel)?.isMuted ?? false

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: detachedBrowserMuted,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            removeBrowserOpenTabSuggestionIfNeeded(panel: detached.panel, panelId: detached.panelId)
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            surfaceTTYNames.removeValue(forKey: detached.panelId)
            surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
            syncRemotePortScanTTYs()
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            restoredUnreadPanelIndicators.removeValue(forKey: detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            if let agentPanel = detached.panel as? AgentSessionPanel {
                agentPanel.onDisplayStateChanged = nil
                agentSessionPanelCallbackIds.remove(detached.panelId)
            }
#if DEBUG
            cmuxDebugLog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
            configureTerminalPanel(terminalPanel)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.reattachToWorkspace(
                id,
                isRemoteWorkspace: isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
                proxyEndpoint: remoteProxyEndpoint,
                remoteStatus: browserRemoteWorkspaceStatusSnapshot()
            )
            configureBrowserPanel(browserPanel)
            installBrowserPanelSubscription(browserPanel)
        } else if let rightSidebarToolPanel = detached.panel as? RightSidebarToolPanel {
            rightSidebarToolPanel.reattach(to: self)
        }
        AppDelegate.shared?.notificationStore?.rebindSurfaceNotifications(
            fromTabId: detached.sourceWorkspaceId,
            toTabId: id,
            surfaceId: detached.panelId
        )
        if let restorableAgent = detached.restorableAgent {
            restoredAgentSnapshotsByPanelId[detached.panelId] = restorableAgent
            invalidatedRestoredAgentFingerprintsByPanelId.removeValue(forKey: detached.panelId)
            if let resumeState = detached.restorableAgentResumeState {
                restoredAgentResumeStatesByPanelId[detached.panelId] = resumeState
            } else {
                restoredAgentResumeStatesByPanelId.removeValue(forKey: detached.panelId)
            }
        } else {
            restoredAgentResumeStatesByPanelId.removeValue(forKey: detached.panelId)
        }
        if let resumeBinding = detached.resumeBinding, !resumeBinding.isProcessDetected {
            surfaceResumeBindingsByPanelId[detached.panelId] = resumeBinding
        } else {
            surfaceResumeBindingsByPanelId.removeValue(forKey: detached.panelId)
        }
        adoptDetachedAgentRuntimeState(detached.agentRuntime)
        if let markdownPanel = detached.panel as? MarkdownPanel,
           panelSubscriptions[markdownPanel.id] == nil {
            installMarkdownPanelSubscription(markdownPanel)
        }
        if let filePreviewPanel = detached.panel as? FilePreviewPanel,
           panelSubscriptions[filePreviewPanel.id] == nil {
            installFilePreviewPanelSubscription(filePreviewPanel)
        }
        if let agentPanel = detached.panel as? AgentSessionPanel {
            agentPanel.updateWorkspaceId(id)
            if !agentSessionPanelCallbackIds.contains(agentPanel.id) {
                installAgentSessionPanelSubscription(agentPanel)
            }
        }
        let didAdoptWorkspaceRemoteTracking = shouldAdoptDetachedWorkspaceRemoteTracking(detached)
        if didAdoptWorkspaceRemoteTracking,
           let remotePTYSessionID = normalizedRemotePTYSessionID(detached.remotePTYSessionID) {
            remotePTYSessionIDsByPanelId[detached.panelId] = remotePTYSessionID
        } else {
            remotePTYSessionIDsByPanelId.removeValue(forKey: detached.panelId)
        }
        if didAdoptWorkspaceRemoteTracking {
            registerRemoteRelayIDAliases(
                snapshotWorkspaceId: detached.sourceWorkspaceId,
                snapshotPanelId: detached.panelId,
                restoredPanelId: detached.panelId
            )
            trackRemoteTerminalSurface(detached.panelId)
        }
        if let cleanupConfiguration = detached.remoteCleanupConfiguration {
            if didAdoptWorkspaceRemoteTracking {
                transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
            } else {
                transferredRemoteCleanupConfigurationsByPanelId[detached.panelId] = cleanupConfiguration
            }
        } else {
            transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
        }
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)
        publishCmuxSurfaceCreated(detached.panelId, paneId: paneId, kind: Self.cmuxEventSurfaceKind(detached.panel), origin: "detach_attach", focused: focus)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId, focusIntent: focusIntent)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        cmuxDebugLog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }

    private func shouldAdoptDetachedWorkspaceRemoteTracking(_ detached: DetachedSurfaceTransfer) -> Bool {
        guard detached.isRemoteTerminal else { return false }
        if detached.sourceWorkspaceId == id { return true }
        guard let detachedRelayPort = detached.remoteRelayPort,
              detachedRelayPort > 0,
              let currentRelayPort = remoteConfiguration?.relayPort,
              currentRelayPort > 0 else {
            return false
        }
        return detachedRelayPort == currentRelayPort
    }
    // MARK: - Focus Management

}
