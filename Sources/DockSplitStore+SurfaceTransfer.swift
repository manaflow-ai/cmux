import AppKit
import Bonsplit
import CmuxTerminal
import CmuxTerminalCore

/// Cross-container surface transfer for the Dock.
///
/// Mirrors `Workspace.detachSurface`/`attachDetachedSurface` so a *live* panel
/// (a running terminal or browser, not a copy) can move between the main split
/// area and a Dock, or between Docks, reusing the same `DetachedSurfaceTransfer`
/// currency the workspace-to-workspace move already uses. The Dock keeps its
/// own panel registry (`panels`/`surfaceIdToPanelId`), so these methods manage
/// that registry directly rather than going through the workspace pane tree.
extension DockSplitStore {
    /// Detaches a live panel from this Dock *without closing it*, packaging it
    /// into a `Workspace.DetachedSurfaceTransfer` for re-attachment elsewhere.
    ///
    /// Ownership is dropped from `panels`/`surfaceIdToPanelId` and the title
    /// subscription cancelled *before* the Bonsplit tab is closed, so the
    /// `didCloseTab` → `reconcilePanels()` path cannot tear the live panel down.
    func detachSurface(panelId: UUID) -> Workspace.DetachedSurfaceTransfer? {
        guard let tabId = surfaceId(forPanelId: panelId), let panel = panels[panelId] else { return nil }
        let kind = (panel.panelType == .browser) ? "browser" : "terminal"
        let icon = panel.displayIcon
        let browser = panel as? BrowserPanel
        let iconImageData = browser?.faviconPNGData
        let isLoading = browser?.isLoading ?? false
        let preservedTransfer = detachedSurfaceTransfersByPanelId.removeValue(forKey: panelId)

        // Drop our ownership first: once the tab close fires `reconcilePanels`,
        // a still-tracked panel would be `panel.close()`d (killing the process).
        panelCancellables[panelId]?.cancel()
        panelCancellables.removeValue(forKey: panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panels.removeValue(forKey: panelId)

        forceCloseDockTabIds.insert(tabId)
        defer { forceCloseDockTabIds.remove(tabId) }
        guard bonsplitController.closeTab(tabId) else {
            // Close rejected: re-take ownership so the Dock stays consistent.
            panels[panelId] = panel
            surfaceIdToPanelId[tabId] = panelId
            if let preservedTransfer {
                detachedSurfaceTransfersByPanelId[panelId] = preservedTransfer
            }
            installSubscription(for: panel, tracksTerminalTitle: true)
            return nil
        }

        // `sourceWorkspaceId` is this Dock's `workspaceId` (not the panel's original
        // workspace) by design: attaching into the Dock re-homed the surface's
        // notification tab-id to `workspaceId` via `updateWorkspaceId`, so any
        // notifications delivered while the panel was docked are keyed under it.
        // `Workspace.attachDetachedSurface` rebinds `fromTabId: sourceWorkspaceId`,
        // so returning the Dock id carries docked-era notifications to the
        // destination workspace; the `preservedTransfer` original id would instead
        // strand them under the (possibly Global-Dock synthetic) id. Consolidating
        // pre-dock notifications is a dock-*entry* rebind concern, out of scope here.
        return Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: workspaceId,
            panelId: panelId,
            panel: panel,
            title: panel.displayTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isLoading: isLoading,
            isPinned: preservedTransfer?.isPinned ?? false,
            directory: preservedTransfer?.directory,
            directoryDisplayLabel: preservedTransfer?.directoryDisplayLabel,
            ttyName: preservedTransfer?.ttyName,
            cachedTitle: preservedTransfer?.cachedTitle,
            customTitle: preservedTransfer?.customTitle,
            customTitleSource: preservedTransfer?.customTitleSource,
            manuallyUnread: preservedTransfer?.manuallyUnread ?? false,
            restoredUnreadIndicator: preservedTransfer?.restoredUnreadIndicator,
            restorableAgent: preservedTransfer?.restorableAgent,
            restorableAgentResumeState: preservedTransfer?.restorableAgentResumeState,
            restorableAgentAutoResumeOnVisit: preservedTransfer?.restorableAgentAutoResumeOnVisit ?? false,
            resumeBinding: preservedTransfer?.resumeBinding,
            agentRuntime: preservedTransfer?.agentRuntime,
            isRemoteTerminal: preservedTransfer?.isRemoteTerminal ?? false,
            remoteRelayPort: preservedTransfer?.remoteRelayPort,
            remotePTYSessionID: preservedTransfer?.remotePTYSessionID,
            remoteCleanupConfiguration: preservedTransfer?.remoteCleanupConfiguration
        )
    }

    /// Attaches a detached live panel into this Dock at `paneId`. Re-targets the
    /// panel to this Dock's workspace id and, for terminals, flips the surface
    /// focus placement to `.rightSidebarDock` so portal layering and focus
    /// routing treat it as a Dock surface (without recreating the surface).
    @discardableResult
    func attachDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard bonsplitController.allPaneIds.contains(paneId), panels[detached.panelId] == nil else { return nil }
        let panel = detached.panel

        if let terminal = panel as? TerminalPanel {
            terminal.surface.setFocusPlacement(.rightSidebarDock)
            terminal.updateWorkspaceId(workspaceId)
        } else if let browser = panel as? BrowserPanel {
            browser.updateWorkspaceId(workspaceId)
        }

        panels[detached.panelId] = panel
        let kind = detached.kind ?? ((panel.panelType == .browser) ? "browser" : "terminal")
        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: kind,
            isDirty: panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: (panel as? BrowserPanel)?.isMuted ?? false,
            // The Dock has no pinned-tab concept (no `pinnedPanelIds`; every Dock
            // `createTab`/`newSurface` site creates unpinned tabs). `detached.isPinned`
            // is intentionally preserved only in the stored transfer above so a
            // workspace→Dock→workspace round-trip restores the pin once the panel
            // lands back in a workspace, where `Workspace.attachDetachedSurface`
            // applies it. Passing it here would create a pin the Dock cannot show.
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            return nil
        }
        surfaceIdToPanelId[newTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        installSubscription(for: panel, tracksTerminalTitle: true)
        // Preserve the full transfer payload — including deferred-resume metadata
        // (`restorableAgentAutoResumeOnVisit`, `resumeBinding`, agent snapshots) —
        // so it survives the Dock round-trip. The Dock has no deferred-resume
        // engine and, like the pre-existing `resumeBinding` path, does not execute
        // pending resume while a panel is docked; `Workspace.attachDetachedSurface`
        // re-arms `restoredAgentAutoResumeOnVisitPanelIds` and reinstalls the
        // resume closure when the panel returns to a workspace, where the next
        // visit resumes it. Running resume from the Dock would require duplicating
        // that Workspace machinery here and is intentionally out of scope.
        detachedSurfaceTransfersByPanelId[detached.panelId] = detached
        withCoalescedTerminalViewReattach {
            applyVisibility(to: panel)
            if let terminal = panel as? TerminalPanel {
                requestTerminalViewReattach(terminal)
            }
            recordExplicitPanelCreation()
            if focus {
                bonsplitController.focusPane(paneId)
                bonsplitController.selectTab(newTabId)
                applyDockSelection(tabId: newTabId, inPane: paneId)
                panel.focus()
            }
        }
        return detached.panelId
    }
}

// MARK: - Tab "Move to…" destinations

extension DockSplitStore {
    static let dockMoveNewWorkspaceDestinationId = "new-workspace"
    static let dockMoveExistingWorkspacePrefix = "workspace:"

    /// Backs `tabContextMoveDestinationsProvider`: offers the same "Move to…"
    /// destinations a main-area tab has — New Workspace plus every other
    /// workspace — so a Dock tab can leave the Dock for a workspace via the tab
    /// context menu, matching `Workspace.bonsplitTabMoveDestinations`.
    func dockTabMoveDestinations(for tabId: TabID) -> [TabContextMoveDestination] {
        guard panel(for: tabId) != nil, let app = AppDelegate.shared else { return [] }
        var destinations: [TabContextMoveDestination] = [
            TabContextMoveDestination(
                id: Self.dockMoveNewWorkspaceDestinationId,
                title: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")
            )
        ]
        // For the Global Dock (no owning workspace) this resolves the active
        // main window; for a Workspace Dock it resolves that workspace's window.
        let referenceWindowId = app.dockReferenceTabManager(for: self).flatMap { app.windowId(for: $0) }
        let targets = app.workspaceMoveTargets(excludingWorkspaceId: workspaceId, referenceWindowId: referenceWindowId)
        destinations.append(contentsOf: targets.map { target in
            TabContextMoveDestination(
                id: Self.dockMoveExistingWorkspacePrefix + target.workspaceId.uuidString,
                title: target.label
            )
        })
        return destinations
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didRequestTabMoveToDestination destinationId: String,
        for tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        guard let panel = panel(for: tab.id), let app = AppDelegate.shared else { return }
        let panelId = panel.id
        if destinationId == Self.dockMoveNewWorkspaceDestinationId {
            _ = app.moveDockSurfaceToNewWorkspace(sourceDock: self, panelId: panelId, focus: true, focusWindow: false)
        } else if destinationId.hasPrefix(Self.dockMoveExistingWorkspacePrefix) {
            let rawWorkspaceId = destinationId.dropFirst(Self.dockMoveExistingWorkspacePrefix.count)
            guard let workspaceId = UUID(uuidString: String(rawWorkspaceId)) else { return }
            _ = app.moveDockSurfaceToWorkspace(
                sourceDock: self,
                panelId: panelId,
                toWorkspace: workspaceId,
                targetPane: nil,
                targetIndex: nil,
                splitTarget: nil,
                focus: true,
                focusWindow: true
            )
        }
    }
}
