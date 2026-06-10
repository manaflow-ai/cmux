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


// MARK: - Terminal surface creation and config inheritance
extension Workspace {
    func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: CmuxSurfaceConfigTemplate?
    ) {
        guard let fontPoints = configTemplate?.fontSize, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: CmuxSurfaceConfigTemplate
    ) -> Float? {
        let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
        if let rooted = terminalInheritanceFontPointsByPanelId[terminalPanel.id], rooted > 0 {
            if let runtimePoints, abs(runtimePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimePoints
            }
            return rooted
        }
        if inheritedConfig.fontSize > 0 {
            return inheritedConfig.fontSize
        }
        return runtimePoints
    }

    func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> CmuxSurfaceConfigTemplate? {
        // Walk candidates in priority order and use the first panel that still exposes
        // a runtime surface pointer.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            // Pin the panel and its TerminalSurface wrapper for the duration of
            // this iteration. The raw ghostty_surface_t extracted below is owned
            // by `surface` (the TerminalSurface) — ARC must not release it while
            // ghostty_surface_inherited_config or cmuxCurrentSurfaceFontSizePoints
            // is still reading through the pointer.
            let surface = terminalPanel.surface
            guard let sourceSurface = surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.fontSize = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            // Prevent ARC from releasing panel/surface before the C calls above complete.
            withExtendedLifetime((terminalPanel, surface)) {}
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.fontSize > 0 {
                lastTerminalConfigInheritanceFontPoints = config.fontSize
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fallbackFontPoints
#if DEBUG
            cmuxDebugLog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> TerminalPanel? {
#if DEBUG
        let splitTimingStart = ProcessInfo.processInfo.systemUptime
        let splitTransport = remoteConfiguration?.transport.rawValue ?? "local"
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=start elapsedMs=0.00"
        )
#endif
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        var inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()
        let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
        let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironment,
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // Hold the pane open after the remote session ends so the user can read the
        // "ssh exited …" message the startup script prints. Otherwise Ghostty silently
        // respawns a local login shell when the command exits (the PTY falls through
        // to $SHELL), and a dead VM looks identical to a healthy workspace with a
        // local prompt — which is what we saw during dogfood.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=command_resolved elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "remoteCommand=\(remoteTerminalStartupCommand == nil ? 0 : 1)"
        )
#endif

        // Inherit working directory: prefer the source panel's reported cwd,
        // then its requested startup cwd if shell integration has not reported
        // back yet, and finally fall back to the workspace's current directory.
        let splitWorkingDirectory: String? = {
            if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workingDirectory.isEmpty {
                return workingDirectory
            }
            if let panelDirectory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !panelDirectory.isEmpty {
                return panelDirectory
            }
            if let requestedWorkingDirectory = terminalPanel(for: panelId)?
                .requestedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedWorkingDirectory.isEmpty {
                return requestedWorkingDirectory
            }
            let workspaceDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceDirectory.isEmpty ? nil : workspaceDirectory
        }()
#if DEBUG
        cmuxDebugLog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") requestedDir=\(terminalPanel(for: panelId)?.requestedWorkingDirectory ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")"
        )
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        let normalizedRemotePTYSessionID = normalizedRemotePTYSessionID(remotePTYSessionID)
        let tracksRemoteTerminalSurface = remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil
        if let normalizedRemotePTYSessionID {
            remotePTYSessionIDsByPanelId[newPanel.id] = normalizedRemotePTYSessionID
            registerRemoteRelayIDAliases(remotePTYSessionID: normalizedRemotePTYSessionID, restoredPanelId: newPanel.id)
        }
        if tracksRemoteTerminalSurface {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=panel_ready elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalPanel?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            remotePTYSessionIDsByPanelId.removeValue(forKey: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            if tracksRemoteTerminalSurface {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }
        applyInitialSplitDividerPosition(initialDividerPosition, sourcePaneId: paneId, newPaneId: newPaneId)
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: focus)

#if DEBUG
        cmuxDebugLog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
        cmuxDebugLog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=layout_committed elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.terminalSplitReparent"
            )
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }
#if DEBUG
        dlog(
            "split.timing workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "transport=\(splitTransport) stage=focus_scheduled elapsedMs=\(debugElapsedMs(since: splitTimingStart)) " +
            "newPanel=\(newPanel.id.uuidString.prefix(5)) focus=\(focus ? 1 : 0)"
        )
#endif

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: newPanel.id,
            reason: "splitCreate"
        )

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        startupEnvironment: [String: String] = [:],
        autoRefreshMetadata: Bool = true,
        preserveFocusWhenUnfocused: Bool = true,
        remotePTYSessionID: String? = nil,
        suppressWorkspaceRemoteStartupCommand: Bool = false
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        var inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let requestedInitialCommand = initialCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitInitialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil
        let remoteTerminalStartupCommand = suppressWorkspaceRemoteStartupCommand ? nil : remoteTerminalStartupCommand()
        let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
        let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: startupEnvironment,
            remoteStartupCommand: remoteStartupCommandForEnvironment
        )
        // See the comment at the other call site: hold the PTY open after the remote
        // command exits so the user sees the error rather than a silently-respawned
        // local login shell.
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        let normalizedRemotePTYSessionID = normalizedRemotePTYSessionID(remotePTYSessionID)
        let tracksRemoteTerminalSurface = remoteTerminalStartupCommand != nil || normalizedRemotePTYSessionID != nil
        if let normalizedRemotePTYSessionID {
            remotePTYSessionIDsByPanelId[newPanel.id] = normalizedRemotePTYSessionID
            registerRemoteRelayIDAliases(remotePTYSessionID: normalizedRemotePTYSessionID, restoredPanelId: newPanel.id)
        }
        if tracksRemoteTerminalSurface {
            trackRemoteTerminalSurface(newPanel.id)
        }
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            remotePTYSessionIDsByPanelId.removeValue(forKey: newPanel.id)
            removeRemoteRelaySurfaceAliases(targeting: newPanel.id)
            if tracksRemoteTerminalSurface {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        publishCmuxSurfaceCreated(newPanel.id, paneId: paneId, kind: "terminal", origin: "terminal_tab", focused: shouldFocusNewTab)

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else if preserveFocusWhenUnfocused || owningTabManager?.selectedTabId == id {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        } else {
            clearNonFocusSplitFocusReassert()
        }

        if autoRefreshMetadata {
            owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: id,
                panelId: newPanel.id,
                reason: "surfaceCreate"
            )
        }
        return newPanel
    }

    /// Replace the terminal process behind an existing surface while preserving its pane and tab identity.
    @discardableResult
    func respawnTerminalSurface(
        panelId: UUID,
        command: String,
        workingDirectory: String? = nil,
        tmuxStartCommand: String? = nil,
        focus: Bool? = nil
    ) -> TerminalPanel? {
        guard let oldPanel = terminalPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return nil
        }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        let requestedWorkingDirectory: String? = {
            if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workingDirectory.isEmpty {
                return workingDirectory
            }
            if let panelDirectory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !panelDirectory.isEmpty {
                return panelDirectory
            }
            if let requestedWorkingDirectory = oldPanel.requestedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedWorkingDirectory.isEmpty {
                return requestedWorkingDirectory
            }
            let workspaceDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceDirectory.isEmpty ? nil : workspaceDirectory
        }()
        let selectedInPane = bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        let paneWasFocused = bonsplitController.focusedPaneId == paneId
        let shouldFocus = focus ?? (selectedInPane && paneWasFocused)
        let customTitle = panelCustomTitles[panelId]
        let wasPinned = pinnedPanelIds.contains(panelId)
        let startCommand = tmuxStartCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementTmuxStartCommand = (startCommand?.isEmpty == false) ? startCommand : trimmedCommand
        let focusPlacement = oldPanel.surface.focusPlacement
        let launchContext = oldPanel.surface.launchContext
        let initialEnvironmentOverrides = oldPanel.surface.respawnInitialEnvironmentOverrides
        let additionalEnvironment = oldPanel.surface.respawnAdditionalEnvironment

        oldPanel.unfocus()
        oldPanel.hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: oldPanel.hostedView)
        oldPanel.surface.beginPortalCloseLifecycle(reason: "terminal.respawn")

        discardClosedPanelLifecycleState(
            panelId: panelId,
            tabId: tabId,
            paneId: paneId,
            panel: oldPanel,
            origin: "terminal_respawn",
            closePanel: false,
            publishSurfaceClosedEvent: false,
            clearSurfaceNotifications: false,
            requestTransferredRemoteCleanup: true,
            cleanupControllerSurfaceState: false
        )
        TerminalSurfaceRegistry.shared.unregister(oldPanel.surface)
        oldPanel.surface.teardownSurface()

        let replacementPanel = TerminalPanel(
            id: panelId,
            workspaceId: id,
            context: launchContext,
            configTemplate: inheritedConfig,
            workingDirectory: requestedWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: trimmedCommand,
            tmuxStartCommand: replacementTmuxStartCommand,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement
        )
        configureNewTerminalPanel(replacementPanel)
        panels[panelId] = replacementPanel
        panelTitles[panelId] = replacementPanel.displayTitle
        if let customTitle {
            panelCustomTitles[panelId] = customTitle
        }
        if wasPinned {
            pinnedPanelIds.insert(panelId)
        }
        surfaceIdToPanelId[tabId] = panelId
        seedTerminalInheritanceFontPoints(panelId: panelId, configTemplate: inheritedConfig)

        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: replacementPanel.displayTitle)
        bonsplitController.updateTab(
            tabId,
            title: resolvedTitle,
            icon: .some(replacementPanel.displayIcon),
            iconImageData: .some(nil),
            kind: .some(SurfaceKind.terminal),
            hasCustomTitle: customTitle != nil,
            isDirty: replacementPanel.isDirty,
            showsNotificationBadge: false,
            isLoading: false,
            isPinned: wasPinned
        )

        if shouldFocus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else if selectedInPane {
            bonsplitController.selectTab(tabId)
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            replacementPanel.unfocus()
        }

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: panelId,
            reason: "terminalRespawn"
        )
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
        return replacementPanel
    }

    func remoteTerminalStartupCommand() -> String? {
        guard !suppressRemoteTerminalStartupForSessionRestoreScaffold else {
            return nil
        }
        guard let command = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

}
