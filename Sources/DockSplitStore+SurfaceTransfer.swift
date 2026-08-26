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
        if let terminalPanel = panel as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalWillLeaveDock(
                    terminalPanel,
                    dock: self
                )
        }
        let preservedTransfer = removeDetachedSurfaceTransfer(forPanelID: panelId)
        let restoredAgentObservation = SharedLiveAgentIndex.shared.index?.entry(
            workspaceId: preservedTransfer?.sessionRestoreWorkspaceId ?? workspaceId,
            panelId: panelId
        )
        let coordinatedRestorableAgent = restoredAgentLifecycle.continuationSnapshot(
            panelId: panelId,
            observation: restoredAgentObservation,
            currentProcessIdentity: Workspace.agentPIDProcessIdentity(pid:)
        )
        let preservedResumeState = restoredAgentLifecycle.resumeStatesByPanelId[panelId]
            ?? preservedTransfer?.restorableAgentResumeState
        let preservedCompletedGeneration = restoredAgentLifecycle.completedGeneration(panelId: panelId)
            ?? preservedTransfer?.restoredAgentCompletedGeneration
        let preservesCompletedAgentExit = preservedResumeState == .completedAgentExit
        let preservedCompletedTombstone = preservesCompletedAgentExit
            ? preservedCompletedGeneration
            : nil
        let preservedRestorableAgent = coordinatedRestorableAgent
            ?? (preservesCompletedAgentExit ? nil : preservedTransfer?.restorableAgent)
        let managedResumeBinding = managedAgentResumeBinding(panelId: panelId)
        let preservedResumeBinding = surfaceResumeBindingsByPanelId[panelId]
        let preservedResumeSessionDirectory = restoredResumeSessionWorkingDirectoriesByPanelId[panelId]
            ?? preservedTransfer?.restoredResumeSessionWorkingDirectory
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
           let terminal = panel as? TerminalPanel {
            liveTerminalDirectory = terminalWorkingDirectoryResolver
                .liveForegroundProcessWorkingDirectory(for: terminal)
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
        // Agent resume metadata can likewise go stale while docked, so re-emit
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
        let cachedRuntime = agentRuntimeByPanelId[panelId] ?? preservedTransfer?.agentRuntime
        let cachedAgentPIDs = (cachedRuntime?.agentPIDs ?? [:]).filter { $0.value > 0 }
        let agentProvenExited = !cachedAgentPIDs.isEmpty && cachedAgentPIDs.allSatisfy { key, pid in
            if let recordedIdentity = cachedRuntime?.agentPIDProcessIdentities[key] {
                return Workspace.agentPIDProcessIdentity(pid: pid) != recordedIdentity
            }
            return Self.dockAgentPIDHasExited(pid)
        }
        let cachedManagedBinding = preservedTransfer?.resolvedManagedAgentResumeBinding
        let bindingSessionWasInvalidated =
            invalidatedCachedTransferAgentSessionPanelIds.contains(panelId)
        let bindingSessionWasReplacedByAnother: Bool = {
            if replacedCachedTransferAgentSessionPanelIds.contains(panelId) {
                return true
            }
            if let cachedManagedBinding {
                guard let managedResumeBinding else {
                    return false
                }
                return !cachedManagedBinding.isSameManagedSession(as: managedResumeBinding)
            }
            guard let managedResumeBinding else {
                return false
            }
            if let originalAgent = preservedRestorableAgent {
                return Workspace.restorableAgentForSessionRestore(
                    originalAgent,
                    resumeBinding: managedResumeBinding
                ) == nil
            }
            return preservedTransfer?.restorableAgentResumeState != nil
                || preservedTransfer?.restoredResumeSessionWorkingDirectory != nil
        }()
        let bindingSessionWasReplaced =
            bindingSessionWasInvalidated || bindingSessionWasReplacedByAnother
        let bindingScopedSessionDirectory = bindingSessionWasReplaced
            ? nil
            : preservedResumeSessionDirectory
        let restoredResumeSessionWorkingDirectory = Self.dockRestoredResumeSessionWorkingDirectory(
            preservedSessionDirectory: bindingScopedSessionDirectory,
            detachedDirectory: detachedDirectory,
            detachedDirectoryWasReadFromLiveForegroundProcess: detachedDirectoryWasReadFromLiveForegroundProcess,
            agentProvenExited: agentProvenExited
        )
        let resumeBinding = Self.dockResumeBinding(
            preservedBinding: preservedResumeBinding,
            preservedSessionDirectory: bindingScopedSessionDirectory,
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            detachedDirectoryWasReadFromLiveForegroundProcess: detachedDirectoryWasReadFromLiveForegroundProcess,
            agentProvenExited: agentProvenExited
        )
        let agentCompatibilityBinding = managedResumeBinding ?? resumeBinding
        let transferredRestorableAgent = agentProvenExited || bindingSessionWasReplaced
            ? nil
            : Workspace.restorableAgentForSessionRestore(
                preservedRestorableAgent,
                resumeBinding: agentCompatibilityBinding
            )
        let rejectedPreservedRestorableAgent =
            preservedRestorableAgent != nil && transferredRestorableAgent == nil
        let preservesRestorableAgentState =
            !agentProvenExited
                && !bindingSessionWasReplaced
                && !rejectedPreservedRestorableAgent
        let transferredResumeState: Workspace.RestoredAgentResumeState?
        let transferredCompletedGeneration: RestoredAgentCompletedGeneration?
        if let preservedCompletedTombstone, !bindingSessionWasReplacedByAnother {
            transferredResumeState = .completedAgentExit
            transferredCompletedGeneration = preservedCompletedTombstone
        } else if preservesRestorableAgentState {
            transferredResumeState = preservedResumeState
            transferredCompletedGeneration = nil
        } else {
            transferredResumeState = nil
            transferredCompletedGeneration = nil
        }
        let trimmedCustomTitle = preservedTransfer?.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transferTitle = trimmedCustomTitle?.isEmpty == false
            ? preservedTransfer?.customTitle
            : panel.displayTitle
        let panelShellActivityState = (panel as? TerminalPanel)?.shellActivity.state
        let transferredShellActivityState = panelShellActivityState == .unknown
            ? preservedTransfer?.shellActivityState
            : panelShellActivityState

        // Drop our ownership first: once the tab close fires `reconcilePanels`,
        // a still-tracked panel would be `panel.close()`d (killing the process).
        appLinkHandoffCoordinator.cancel(sourcePanelID: panelId)
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
                setDetachedSurfaceTransfer(
                    preservedTransfer,
                    forPanelID: panelId
                )
            }
            installSubscription(for: panel, tracksTerminalTitle: true)
            return nil
        }
        if let terminalPanel = panel as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalDidLeaveDock(
                    terminalPanel,
                    dock: self,
                    preservingTransfer: true
                )
        }

        let detached = Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: workspaceId,
            sessionRestoreSourceWorkspaceId: preservedTransfer?.sessionRestoreWorkspaceId,
            panelId: panelId,
            panel: panel,
            title: transferTitle ?? panel.displayTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isLoading: isLoading,
            isPinned: false,
            directory: detachedDirectory,
            directoryIsTrustedRemoteReport: detachedDirectory != nil &&
                detachedDirectory == preservedTransfer?.directory &&
                preservedTransfer?.directoryIsTrustedRemoteReport == true,
            directoryDisplayLabel: detachedDirectory == preservedTransfer?.directory
                ? preservedTransfer?.directoryDisplayLabel
                : nil,
            ttyName: preservedTransfer?.ttyName,
            ttyNameWasReportedByCurrentRuntime: preservedTransfer?.ttyNameWasReportedByCurrentRuntime ?? false,
            ttyReportRuntimeSurfaceGeneration: preservedTransfer?.ttyReportRuntimeSurfaceGeneration,
            cachedTitle: panel.displayTitle,
            customTitle: preservedTransfer?.customTitle,
            customTitleSource: preservedTransfer?.customTitleSource,
            manuallyUnread: preservedTransfer?.manuallyUnread ?? false,
            restoredUnreadIndicator: preservedTransfer?.restoredUnreadIndicator,
            restorableAgent: transferredRestorableAgent,
            restorableAgentResumeState: transferredResumeState,
            restoredAgentCompletedGeneration: transferredCompletedGeneration,
            shellActivityState: transferredShellActivityState,
            restoredPanelTitleBoundary: preservedTransfer?.restoredPanelTitleBoundary,
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            resumeBinding: resumeBinding,
            managedAgentResumeBinding: managedResumeBinding,
            agentRuntime: agentProvenExited ? nil : cachedRuntime,
            // Only reports accepted while Dock-owned are authoritative. The
            // runtime keeps entry-time lifecycle values for guard routing, but
            // those cached values never enter this transfer record map.
            agentLifecycleRecords: agentProvenExited
                ? [:]
                : cachedRuntime?.authoritativeAgentLifecycleRecords ?? [:],
            isRemoteTerminal: preservedTransfer?.isRemoteTerminal ?? false,
            remoteTerminalSessionPhase: preservedTransfer?.remoteTerminalSessionPhase,
            remoteTerminalAuthority: preservedTransfer?.remoteTerminalAuthority,
            remoteTerminalLifecycleID: preservedTransfer?.remoteTerminalLifecycleID,
            remoteTerminalAttemptID: preservedTransfer?.remoteTerminalAttemptID,
            remoteRelayPort: preservedTransfer?.remoteRelayPort,
            remoteRelayNamespaceConfiguration: preservedTransfer?.remoteRelayNamespaceConfiguration,
            remotePTYSessionID: preservedTransfer?.remotePTYSessionID,
            remoteCleanupConfiguration: preservedTransfer?.remoteCleanupConfiguration
        )
        clearSessionRestoreState(panelId: panelId, publishLifecycleExit: false)
        return detached
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
        setDetachedSurfaceTransfer(detached, forPanelID: detached.panelId)
        adoptSessionRestoreState(from: detached)
        let kind = detached.kind ?? ((panel.panelType == .browser) ? "browser" : "terminal")
        let restoredIconImageData = detached.panel is TerminalPanel ? nil : detached.iconImageData
        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            icon: detached.icon,
            iconImageData: restoredIconImageData,
            kind: kind,
            isDirty: panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: (panel as? BrowserPanel)?.isMuted ?? false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            removeDetachedSurfaceTransfer(forPanelID: detached.panelId)
            clearSessionRestoreState(panelId: detached.panelId, publishLifecycleExit: false)
            return nil
        }
        surfaceIdToPanelId[newTabId] = detached.panelId
        if let browser = panel as? BrowserPanel {
            configureBrowserPanel(browser)
        }
        AgentHibernationController.shared.transferTrackingStateForMovedPanel(
            panelId: detached.panelId,
            from: detached.sourceWorkspaceId,
            to: workspaceId
        )
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        finishAttachingDetachedSurface(
            panel,
            tabId: newTabId,
            inPane: paneId,
            focus: focus,
            reconcileReason: "dock.attachDetachedSurface"
        )
        if let terminalPanel = panel as? TerminalPanel {
            if let owningWorkspace =
                    terminalFontSizeOwningWorkspace {
                terminalPanel.fontSizePanelTransfer?.attach(
                    to: owningWorkspace
                )
            } else {
                terminalPanel.fontSizePanelTransfer?.attach(
                    to: self
                )
            }
            terminalFontSizeChangeCoordinator?
                .terminalDidEnterDock(
                    terminalPanel,
                    dock: self
                )
        }
        return detached.panelId
    }

    /// Attaches a detached live panel directly into a newly split Dock pane.
    ///
    /// Unlike attaching to `paneId` and then moving that tab into a split, this
    /// publishes exactly one portal host for the transferred panel. Registering
    /// ownership before the single Bonsplit mutation also lets the synchronous
    /// split delegate and portal reconciler resolve the live panel immediately.
    @discardableResult
    func attachDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        bySplitting paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool = true
    ) -> UUID? {
        guard bonsplitController.allPaneIds.contains(paneId), panels[detached.panelId] == nil else {
            return nil
        }
        let panel = detached.panel

        if let terminal = panel as? TerminalPanel {
            terminal.surface.setFocusPlacement(.rightSidebarDock)
            terminal.updateWorkspaceId(workspaceId)
        } else if let browser = panel as? BrowserPanel {
            browser.updateWorkspaceId(workspaceId)
        }

        let kind = detached.kind ?? ((panel.panelType == .browser) ? "browser" : "terminal")
        let tab = Bonsplit.Tab(
            title: detached.title,
            icon: detached.icon,
            iconImageData: panel is TerminalPanel ? nil : detached.iconImageData,
            kind: kind,
            isDirty: panel.isDirty,
            isLoading: detached.isLoading,
            isAudioMuted: (panel as? BrowserPanel)?.isMuted ?? false,
            isPinned: false
        )

        panels[detached.panelId] = panel
        setDetachedSurfaceTransfer(detached, forPanelID: detached.panelId)
        adoptSessionRestoreState(from: detached)
        surfaceIdToPanelId[tab.id] = detached.panelId

        let newPane = withProgrammaticDockSplit {
            bonsplitController.splitPane(
                paneId,
                orientation: orientation,
                withTab: tab,
                insertFirst: insertFirst
            )
        }
        guard let newPane else {
            surfaceIdToPanelId.removeValue(forKey: tab.id)
            removeDetachedSurfaceTransfer(forPanelID: detached.panelId)
            panels.removeValue(forKey: detached.panelId)
            clearSessionRestoreState(panelId: detached.panelId, publishLifecycleExit: false)
            return nil
        }
        if let browser = panel as? BrowserPanel {
            configureBrowserPanel(browser)
        }
        AgentHibernationController.shared.transferTrackingStateForMovedPanel(
            panelId: detached.panelId,
            from: detached.sourceWorkspaceId,
            to: workspaceId
        )

        repairPlaceholderOnlyDockPane(paneId)
        finishAttachingDetachedSurface(
            panel,
            tabId: tab.id,
            inPane: newPane,
            focus: focus,
            reconcileReason: "dock.attachDetachedSurface.split"
        )
        if let terminalPanel = panel as? TerminalPanel {
            if let owningWorkspace =
                    terminalFontSizeOwningWorkspace {
                terminalPanel.fontSizePanelTransfer?.attach(
                    to: owningWorkspace
                )
            } else {
                terminalPanel.fontSizePanelTransfer?.attach(
                    to: self
                )
            }
            terminalFontSizeChangeCoordinator?
                .terminalDidEnterDock(
                    terminalPanel,
                    dock: self
                )
        }
        return detached.panelId
    }

    private func finishAttachingDetachedSurface(
        _ panel: any Panel,
        tabId: TabID,
        inPane paneId: PaneID,
        focus: Bool,
        reconcileReason: String
    ) {
        installSubscription(for: panel, tracksTerminalTitle: true)
        withCoalescedTerminalViewReattach {
            applyVisibility(to: panel)
            if let terminal = panel as? TerminalPanel {
                requestTerminalViewReattach(terminal)
            }
            recordExplicitPanelCreation()
            if focus {
                bonsplitController.focusPane(paneId)
                bonsplitController.selectTab(tabId)
                applyDockSelection(tabId: tabId, inPane: paneId)
            }
        }
        scheduleDockPortalReconcile(reason: reconcileReason)
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
