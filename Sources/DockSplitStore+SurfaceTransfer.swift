import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxTerminal
import CmuxTerminalCore
import Darwin

/// Cross-container surface transfer for the Dock.
///
/// Mirrors `Workspace.detachSurface`/`attachDetachedSurface` so a *live* panel
/// (a running terminal or browser, not a copy) can move between the main split
/// area and a Dock, or between Docks, reusing the same `DetachedSurfaceTransfer`
/// currency the workspace-to-workspace move already uses. The Dock keeps its
/// own panel registry (`panels`/`surfaceIdToPanelId`), so these methods manage
/// that registry directly rather than going through the workspace pane tree.
extension DockSplitStore {
    static func dockAgentPIDProbeIndicatesExited(result: Int32, errnoCode: Int32) -> Bool {
        result != 0 && errnoCode == ESRCH
    }

    /// Computes the resume-cwd rescue value to carry out of the Dock. A nil
    /// preserved value means cwd tracking was intentionally suppressed.
    static func dockRestoredResumeSessionWorkingDirectory(
        preservedSessionDirectory: String?,
        detachedDirectory: String?,
        detachedDirectoryWasReadFromLiveForegroundProcess: Bool,
        agentProvenExited: Bool
    ) -> String? {
        guard !agentProvenExited else { return nil }
        guard preservedSessionDirectory != nil else { return nil }
        return detachedDirectoryWasReadFromLiveForegroundProcess
            ? detachedDirectory
            : preservedSessionDirectory
    }

    static func dockResumeBinding(
        preservedBinding: SurfaceResumeBindingSnapshot?,
        preservedSessionDirectory: String?,
        restoredResumeSessionWorkingDirectory: String?,
        detachedDirectoryWasReadFromLiveForegroundProcess: Bool,
        agentProvenExited: Bool
    ) -> SurfaceResumeBindingSnapshot? {
        guard !agentProvenExited, let preservedBinding else { return nil }
        guard detachedDirectoryWasReadFromLiveForegroundProcess,
              let preservedSessionDirectory,
              let restoredResumeSessionWorkingDirectory else {
            return preservedBinding
        }
        let resolvedWorkingDirectory = AgentResumeWorkingDirectory().resolve(
            kind: preservedBinding.kind ?? "",
            runtimeCwd: restoredResumeSessionWorkingDirectory,
            launchWorkingDirectory: preservedSessionDirectory
        )
        guard resolvedWorkingDirectory != preservedBinding.cwd else { return preservedBinding }
        return preservedBinding.retargetingWorkingDirectory(resolvedWorkingDirectory)
    }

    private static func dockAgentPIDHasExited(_ pid: pid_t) -> Bool {
        errno = 0
        let result = Darwin.kill(pid, 0)
        return dockAgentPIDProbeIndicatesExited(result: result, errnoCode: errno)
    }

    /// Detaches a live panel from this Dock *without closing it*, packaging it
    /// into a `Workspace.DetachedSurfaceTransfer` for re-attachment elsewhere.
    ///
    /// Ownership is dropped from `panels`/`surfaceIdToPanelId` and the title
    /// subscription cancelled *before* the Bonsplit tab is closed, so the
    /// `didCloseTab` → `reconcilePanels()` path cannot tear the live panel down.
    func detachSurface(panelId: UUID) -> Workspace.DetachedSurfaceTransfer? {
        guard let tabId = surfaceId(forPanelId: panelId), let panel = panels[panelId] else { return nil }
        let preservedTransfer = detachedSurfaceTransfersByPanelId.removeValue(forKey: panelId)
        let kind = (panel.panelType == .browser) ? "browser" : "terminal"
        let icon = panel.displayIcon
        let browser = panel as? BrowserPanel
        let iconImageData = browser?.faviconPNGData
        let isLoading = browser?.isLoading ?? false
        // The Dock has no cwd-report routing, so a preserved transfer's
        // directory is frozen at Dock-entry time and goes stale if the
        // terminal cds while docked. Prefer the live foreground process's
        // actual cwd at detach time. Local panes only: a remote pane's
        // foreground process is the local relay, not the remote shell.
        let liveTerminalDirectory: String?
        if preservedTransfer?.isRemoteTerminal != true,
           let terminal = panel as? TerminalPanel,
           let pid = terminal.surface.foregroundProcessID() {
            liveTerminalDirectory = Workspace.processCurrentWorkingDirectory(pid: Int32(clamping: pid))
        } else {
            liveTerminalDirectory = nil
        }
        let detachedDirectory: String?
        var liveTerminalDirectoryIsDirectory: ObjCBool = false
        if let liveTerminalDirectory,
           FileManager.default.fileExists(atPath: liveTerminalDirectory, isDirectory: &liveTerminalDirectoryIsDirectory),
           liveTerminalDirectoryIsDirectory.boolValue {
            detachedDirectory = liveTerminalDirectory
        } else {
            detachedDirectory = preservedTransfer?.directory
        }
        let detachedDirectoryWasReadFromLiveForegroundProcess =
            liveTerminalDirectory != nil && detachedDirectory == liveTerminalDirectory
        // Agent resume metadata can likewise go stale while docked (the Dock
        // receives no shell-activity or agent lifecycle updates), so re-emit
        // it only while the agent is not proven dead: recorded agent pids
        // exist and none is still running. Where the transfer recorded a
        // process start-time identity, compare it so a reused pid does not
        // masquerade as the exited agent (same contract as
        // `isRecordedAgentPIDLive`); without one, fall back to the ESRCH
        // probe. The workspace lifecycle clears the same metadata when an
        // agent exits at a prompt, so this mirrors it. An empty pid set stays
        // preserved — a restored-but-unscanned agent has no pids yet, and
        // dropping it would reintroduce the Dock round-trip metadata loss
        // #7155 fixes.
        let cachedRuntime = preservedTransfer?.agentRuntime
        let cachedAgentPIDs = (cachedRuntime?.agentPIDs ?? [:]).filter { $0.value > 0 }
        let agentProvenExited = !cachedAgentPIDs.isEmpty && cachedAgentPIDs.allSatisfy { key, pid in
            if let recordedIdentity = cachedRuntime?.agentPIDProcessIdentities[key] {
                return Workspace.agentPIDProcessIdentity(pid: pid) != recordedIdentity
            }
            return Self.dockAgentPIDHasExited(pid)
        }
        let restoredResumeSessionWorkingDirectory = Self.dockRestoredResumeSessionWorkingDirectory(
            preservedSessionDirectory: preservedTransfer?.restoredResumeSessionWorkingDirectory,
            detachedDirectory: detachedDirectory,
            detachedDirectoryWasReadFromLiveForegroundProcess: detachedDirectoryWasReadFromLiveForegroundProcess,
            agentProvenExited: agentProvenExited
        )
        let resumeBinding = Self.dockResumeBinding(
            preservedBinding: preservedTransfer?.resumeBinding,
            preservedSessionDirectory: preservedTransfer?.restoredResumeSessionWorkingDirectory,
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            detachedDirectoryWasReadFromLiveForegroundProcess: detachedDirectoryWasReadFromLiveForegroundProcess,
            agentProvenExited: agentProvenExited
        )
        let trimmedCustomTitle = preservedTransfer?.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transferTitle = trimmedCustomTitle?.isEmpty == false
            ? preservedTransfer?.customTitle
            : panel.displayTitle

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
            title: transferTitle ?? panel.displayTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isLoading: isLoading,
            isPinned: false,
            directory: detachedDirectory,
            directoryDisplayLabel: detachedDirectory == preservedTransfer?.directory
                ? preservedTransfer?.directoryDisplayLabel
                : nil,
            ttyName: preservedTransfer?.ttyName,
            cachedTitle: panel.displayTitle,
            customTitle: preservedTransfer?.customTitle,
            customTitleSource: preservedTransfer?.customTitleSource,
            manuallyUnread: preservedTransfer?.manuallyUnread ?? false,
            restoredUnreadIndicator: preservedTransfer?.restoredUnreadIndicator,
            restorableAgent: agentProvenExited ? nil : preservedTransfer?.restorableAgent,
            restorableAgentResumeState: agentProvenExited ? nil : preservedTransfer?.restorableAgentResumeState,
            restorableAgentAutoResumeOnVisit: agentProvenExited ? false : (preservedTransfer?.restorableAgentAutoResumeOnVisit ?? false),
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            resumeBinding: resumeBinding,
            agentRuntime: agentProvenExited ? nil : preservedTransfer?.agentRuntime,
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
        // Cache the transfer as-is, transient resume state included: while the
        // agent is alive that state (and the #7155 rescue directory) is still
        // current, and `detachSurface` drops all agent metadata once the
        // recorded processes are proven dead. Stripping here instead would
        // lose the rescue for live agents whenever the detach-time live cwd
        // read is unavailable.
        detachedSurfaceTransfersByPanelId[detached.panelId] = detached
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
            detachedSurfaceTransfersByPanelId.removeValue(forKey: detached.panelId)
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
        //
        // This snapshot is frozen at dock-entry and never refreshed while docked,
        // which is correct: the Dock tracks none of the workspace's per-panel
        // state (no `panelDirectories`, `surfaceTTYNames`, `panelTitles`,
        // `panelCustomTitles`, `pinnedPanelIds`, or `manualUnreadPanelIds`), so it
        // has no fresher value to record. Dock-immutable fields (pin, custom
        // title, manual-unread, agent/resume snapshots, remote identity) have no
        // mutation path here at all. Live terminal-derived fields (`directory`,
        // `ttyName`) are re-seeded from this payload on re-attach and then
        // corrected by the live terminal's own reporting once
        // `Workspace.attachDetachedSurface` restores workspace tracking
        // (`updatePanelDirectory(source: .liveReport)`); `title` is already read
        // live at detach above. Preserving this payload is strictly better than
        // the prior behavior of dropping all of it (nil/false) on a Dock round-
        // trip. If a future Dock feature can mutate any of these fields, refresh
        // this entry at that point.
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
        // A window Dock resolves its owning window; a Workspace Dock resolves
        // that workspace's window (see `dockReferenceTabManager`).
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
