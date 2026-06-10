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


// MARK: - Bonsplit tab bar delegate callbacks
extension Workspace {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseState() {
            if controller.zoomedPaneId == pane,
               controller.selectedTab(inPane: pane)?.id == tab.id {
                postCloseClearSplitZoomTabIds.insert(tab.id)
            } else {
                postCloseClearSplitZoomTabIds.remove(tab.id)
            }

            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        let tabCloseButtonClose = tabCloseButtonCloseTabIds.remove(tab.id) != nil
        let explicitUserClose = explicitUserCloseTabIds.remove(tab.id) != nil || tabCloseButtonClose

        if forceCloseTabIds.contains(tab.id) {
            if !pushClosedPanelHistoryIfEligible(for: tab, inPane: pane) {
                stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            } else {
                clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            }
            recordPostCloseState()
            return true
        }

        let closeConfirmationManager = owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        if let closeConfirmationManager, closeConfirmationManager.isCloseConfirmationInFlight {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }
            clearCloseHistoryEligibility(tabId: tab.id)
            return false
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            clearCloseHistoryEligibility(tabId: tab.id, panelId: panelId)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            clearCloseHistoryEligibility(tabId: tab.id)
            if tabCloseButtonClose {
                owningTabManager?.closeWorkspaceFromTabCloseButton(self)
            } else {
                owningTabManager?.closeWorkspaceFromCloseTabGesture(self)
            }
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseState()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        let confirmationSource: CloseTabConfirmationPolicy.Source = tabCloseButtonClose ? .tabCloseButton : .shortcut
        if CloseTabConfirmationPolicy.shouldConfirm(
            requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
            source: confirmationSource
        ) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            let confirmationManager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
            if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    confirmationManager?.endCloseConfirmationSession()
                    return
                }
                Task { @MainActor in
                    defer {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        confirmationManager?.endCloseConfirmationSession()
                    }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else {
                        self.clearCloseHistoryEligibility(tabId: tabId)
                        return
                    }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        if !pushClosedPanelHistoryIfEligible(for: tab, inPane: pane) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
        } else {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
        }
        recordPostCloseState()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        tabCloseButtonCloseTabIds.remove(tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let shouldClearSplitZoom = postCloseClearSplitZoomTabIds.remove(tabId) != nil
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
        let isDetaching = detachingTabIds.remove(tabId) != nil || isDetachingCloseTransaction
        if shouldClearSplitZoom {
            clearSplitZoom()
        }

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]
        _ = consumeCloseHistoryEligibility(tabId: tabId, panelId: panelId)
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[panelId]
        let preservesSurfaceForDetach = isDetaching && panel != nil

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            let cachedTitle = panelTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            let restorableAgent = restoredAgentSnapshotsByPanelId[panelId]
            let restorableAgentResumeState = restoredAgentResumeStatesByPanelId[panelId]
            let resumeBinding = effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
            let agentRuntime = agentRuntimeState(forPanelId: panelId)
            pendingDetachedSurfaces[tabId] = DetachedSurfaceTransfer(
                sourceWorkspaceId: id,
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                kind: surfaceKind(for: panel),
                isLoading: browserPanel?.isLoading ?? false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectories[panelId],
                ttyName: surfaceTTYNames[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                manuallyUnread: manualUnreadPanelIds.contains(panelId),
                restoredUnreadIndicator: restoredUnreadPanelIndicators[panelId],
                restorableAgent: restorableAgent,
                restorableAgentResumeState: restorableAgentResumeState,
                resumeBinding: resumeBinding,
                agentRuntime: agentRuntime,
                isRemoteTerminal: activeRemoteTerminalSurfaceIds.contains(panelId),
                remoteRelayPort: activeRemoteTerminalSurfaceIds.contains(panelId)
                    ? remoteConfiguration?.relayPort
                    : nil,
                remotePTYSessionID: remotePTYSessionIDForSnapshot(panelId: panelId),
                remoteCleanupConfiguration: transferredRemoteCleanupConfiguration
            )
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
        }

        let closedRemoteCleanupConfiguration = discardClosedPanelLifecycleState(
            panelId: panelId,
            tabId: tabId,
            paneId: pane,
            panel: panel,
            origin: "tab_close",
            closePanel: !isDetaching,
            publishSurfaceClosedEvent: !isDetaching,
            clearSurfaceNotifications: !preservesSurfaceForDetach,
            requestTransferredRemoteCleanup: false,
            cleanupControllerSurfaceState: !isDetaching
        )
        if !isDetaching {
            owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
        }
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        if !isDetaching, let cleanupConfiguration = closedRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        }

        // Keep the workspace invariant for normal close paths.
        // Detach/move flows intentionally allow a temporary empty workspace so AppDelegate can
        // prune the source workspace/window after the tab is attached elsewhere.
        if panels.isEmpty {
            if isDetaching {
                // Detach path also doesn't create a replacement panel this turn, so any
                // pending banner state would survive and leak into a later close. Drop it.
                pendingReplacementBannerRemoteTarget = nil
                scheduleTerminalGeometryReconcile()
                return
            }

            #if DEBUG
            dlog("replacement.banner.fire target=\(pendingReplacementBannerRemoteTarget ?? "nil")")
            #endif
            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        // A remote terminal exited but sibling panels are still alive, so we won't spawn a
        // replacement right now. Drop the banner-target — without this, a later unrelated
        // close (e.g. a local pane shuts down its shell) would inherit the stale value and
        // print "remote ssh session ended" for a flow that had nothing to do with the VM.
        pendingReplacementBannerRemoteTarget = nil

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            // When closing the last tab in a pane, Bonsplit may focus a different pane and skip
            // emitting didSelectTab. Re-apply the focused selection so sidebar state stays in sync.
            applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = panelIdFromSurfaceId(tab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        cmuxDebugLog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        cmuxDebugLog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
#if DEBUG
        let movedPanelIdAfter = panelIdFromSurfaceId(tab.id)
#endif
        if let movedPanelId = panelIdFromSurfaceId(tab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
        cmuxDebugLog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        AppDelegate.shared?.focusLog.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
        let closedHistoryEntries = pendingPaneCloseHistoryEntries.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        publishCmuxPaneClosed(paneId, closedPanelIds: closedPanelIds, origin: "pane_close")
        if !closedPanelIds.isEmpty {
            if !isDetachingCloseTransaction && !suppressClosedPanelHistory {
                for entry in closedHistoryEntries {
                    ClosedItemHistoryStore.shared.push(.panel(entry))
                }
            }

            for panelId in closedPanelIds {
                let panel = panels[panelId]
                discardClosedPanelLifecycleState(
                    panelId: panelId,
                    tabId: surfaceIdFromPanelId(panelId),
                    paneId: paneId,
                    panel: panel,
                    origin: "pane_close",
                    closePanel: true,
                    publishSurfaceClosedEvent: true,
                    clearSurfaceNotifications: true,
                    requestTransferredRemoteCleanup: true,
                    cleanupControllerSurfaceState: !isDetachingCloseTransaction
                )
                if !isDetachingCloseTransaction {
                    owningTabManager?.invalidateFocusHistoryTarget(workspaceId: id, panelId: panelId)
                }
            }

            syncRemotePortScanTTYs()
            recomputeListeningPorts()
            clearRemoteConfigurationIfWorkspaceBecameLocal()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               CloseTabConfirmationPolicy.shouldConfirm(
                   requiresConfirmation: panelNeedsConfirmClose(panelId: panelId),
                   source: .shortcut
               ) {
                pendingPaneClosePanelIds.removeValue(forKey: pane.id)
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
                return false
            }
        }
        let panelIds = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        pendingPaneClosePanelIds[pane.id] = panelIds
        if suppressClosedPanelHistory || isDetachingCloseTransaction {
            pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
        } else {
            let historyEntries = tabs.compactMap { tab -> ClosedPanelHistoryEntry? in
                guard let panelId = panelIdFromSurfaceId(tab.id) else { return nil }
                return closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane)
            }
            if historyEntries.isEmpty {
                pendingPaneCloseHistoryEntries.removeValue(forKey: pane.id)
            } else {
                pendingPaneCloseHistoryEntries[pane.id] = historyEntries
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        cmuxDebugLog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        let rearmBrowserPortalHostReplacement: (PaneID, String) -> Void = { paneId, reason in
            for tab in controller.tabs(inPane: paneId) {
                guard let panelId = self.panelIdFromSurfaceId(tab.id),
                      let browserPanel = self.browserPanel(for: panelId) else {
                    continue
                }
                browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                    inPane: paneId,
                    reason: reason
                )
            }
        }
        rearmBrowserPortalHostReplacement(originalPane, "workspace.didSplit.original")
        rearmBrowserPortalHostReplacement(newPane, "workspace.didSplit.new")

        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            cmuxDebugLog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                cmuxDebugLog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal
                    )
                    configureNewTerminalPanel(replacementPanel)
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    seedTerminalInheritanceFontPoints(panelId: replacementPanel.id, configTemplate: inheritedConfig)
                    surfaceIdToPanelId[replacementTab.id] = replacementPanel.id

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )
                    publishCmuxSurfaceCreated(replacementPanel.id, paneId: originalPane, kind: "terminal", origin: "placeholder_repair", focused: false)

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    cmuxDebugLog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourcePanelId,
            inPane: originalPane
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        normalizePinnedTabs(in: newPane)
        publishCmuxSplitCreated(newPane, sourcePaneId: originalPane, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "ui_split", focused: true)
#if DEBUG
        cmuxDebugLog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabMoveToDestination destinationId: String, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        _ = moveBonsplitTab(tab.id, toMoveDestination: destinationId)
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        tmuxLayoutSnapshot = snapshot
        // Every order/membership mutation (same-pane reorder, cross-pane move,
        // split, close) routes through here. A pure reorder mutates only
        // bonsplit's internal state, which is not `@Published`, so observers
        // would miss it. Bump `paneLayoutVersion` only when the ordered panel-id
        // sequence actually changed, so divider drags and selection-only events
        // (also routed here) do not fire `objectWillChange` app-wide.
        let currentOrder = orderedPanelIds
        if currentOrder != lastOrderedPanelIds {
            lastOrderedPanelIds = currentOrder
            paneLayoutVersion &+= 1
        }
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
