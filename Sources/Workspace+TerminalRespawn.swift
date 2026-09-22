import AppKit
import Bonsplit
import CmuxCore
import CmuxTerminal
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Replace the terminal process behind an existing surface while preserving its pane and tab identity.
    /// Passing `nil` for `command` starts the same default shell as a newly created terminal.
    @discardableResult
    func respawnTerminalSurface(
        panelId: UUID,
        command: String?,
        workingDirectory: String? = nil,
        tmuxStartCommand: String? = nil,
        focus: Bool? = nil,
        waitAfterCommand: Bool? = nil,
        replayScrollback: String? = nil,
        replayFileURL: URL? = nil,
        allowTextBoxFocusDefault: Bool = true
    ) -> TerminalPanel? {
        guard !isRetiredFromOwningTabManager,
              let oldPanel = terminalPanel(for: panelId),
              let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return nil
        }

        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command != nil, trimmedCommand?.isEmpty != false { return nil }

        var inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)
        var respawnConfig = inheritedConfig ?? CmuxSurfaceConfigTemplate()
        respawnConfig.waitAfterCommand = waitAfterCommand ?? oldPanel.surface.debugWaitAfterCommand()
        inheritedConfig = respawnConfig
        let requestedWorkingDirectory = resolvedTerminalStartupWorkingDirectory(
            requestedWorkingDirectory: workingDirectory,
            sourcePanelId: panelId
        )
        let selectedInPane = bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        let paneWasFocused = bonsplitController.focusedPaneId == paneId
        let shouldFocus = focus ?? (selectedInPane && paneWasFocused)
        let customTitle = panelCustomTitles[panelId]
        let customTitleSource = panelCustomTitleSources[panelId]
        let wasPinned = pinnedPanelIds.contains(panelId)
        let startCommand = tmuxStartCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementTmuxStartCommand = (startCommand?.isEmpty == false) ? startCommand : trimmedCommand
        let focusPlacement = oldPanel.surface.focusPlacement
        let launchContext = oldPanel.surface.launchContext
        // Drop env this surface inherited from its (possibly previous) workspace,
        // then re-fold the current workspace's env below, so a terminal moved
        // between workspaces respawns with the destination's variables rather than
        // the source's (#5995). Only entries whose value still equals the seeded
        // workspace value are dropped, so an explicit per-surface override that
        // shares a workspace key keeps its value. configureNewTerminalPanel
        // re-records the seeded env for the replacement panel against the current
        // workspace.
        let oldSeededWorkspaceEnvironment = oldPanel.seededWorkspaceEnvironment
        let initialEnvironmentOverrides = oldPanel.surface.respawnInitialEnvironmentOverrides
            .filter { oldSeededWorkspaceEnvironment[$0.key] != $0.value }
        var additionalEnvironment = startupEnvironmentMergingWorkspaceEnvironment(
            oldPanel.surface.respawnAdditionalEnvironment.filter { oldSeededWorkspaceEnvironment[$0.key] != $0.value }
        )
        let effectiveReplayFileURL = replayFileURL ?? SessionScrollbackReplayStore.replayFileURL(for: replayScrollback)
        for (key, value) in SessionScrollbackReplayStore.replayEnvironment(forFileURL: effectiveReplayFileURL) {
            additionalEnvironment[key] = value
        }

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
            discardAgentHibernationTracking: false,
            cleanupControllerSurfaceState: false,
            preservesRemoteTerminalTracking: true
        )
        oldPanel.removeOwnedSessionScrollbackReplayArtifact()
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
        replacementPanel.adoptOwnedSessionScrollbackReplayArtifact(effectiveReplayFileURL)
        // Respawn replaces the panel object but keeps the logical tab identity.
        replacementPanel.adoptStableSurfaceId(oldPanel.stableSurfaceId)
        configureNewTerminalPanel(
            replacementPanel,
            allowTextBoxFocusDefault: shouldFocus && allowTextBoxFocusDefault
        )
        panels[panelId] = replacementPanel
        panelTitles[panelId] = replacementPanel.displayTitle
        if let customTitle {
            panelCustomTitles[panelId] = customTitle
            panelCustomTitleSources[panelId] = customTitleSource ?? .user
        }
        if wasPinned {
            pinnedPanelIds.insert(panelId)
        }
        bindSurface(tabId, toPanelId: panelId)
        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: replacementPanel.displayTitle)
        bonsplitController.updateTab(
            tabId,
            title: resolvedTitle,
            icon: .some(replacementPanel.displayIcon),
            iconImageData: .some(nil),
            iconAsset: .some(nil),
            kind: .some(SurfaceKind.terminal.rawValue),
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
        rememberTerminalConfigInheritanceSource(replacementPanel)

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: panelId,
            reason: "terminalRespawn"
        )
        markRemoteTerminalSessionLaunching(surfaceId: panelId)
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
        return replacementPanel
    }
}
