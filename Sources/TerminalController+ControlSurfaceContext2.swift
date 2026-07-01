import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

/// The surface-domain lifecycle witnesses (`split` / `respawn` / `create` /
/// `close` / `move` / `reorder`) plus the browser-disabled mapping and the
/// localized respawn strings. Split out of `TerminalController+ControlSurfaceContext`
/// to keep the conformance readable; see that file's doc comment for the overview.
extension TerminalController {
    func controlSurfaceRespawnStrings() -> ControlSurfaceRespawnStrings {
        ControlSurfaceRespawnStrings(
            invalidFocus: String(
                localized: "rpc.v2.surface.respawn.invalidFocus",
                defaultValue: "Missing or invalid focus"
            ),
            failed: String(
                localized: "rpc.v2.surface.respawn.failed",
                defaultValue: "Failed to respawn surface"
            ),
            surfaceNotFoundForID: String(
                localized: "rpc.v2.surface.respawn.surfaceNotFoundForId",
                defaultValue: "Surface not found for the given surface_id"
            ),
            tabManagerUnavailable: String(
                localized: "rpc.v2.surface.respawn.tabManagerUnavailable",
                defaultValue: "Unable to access the target workspace"
            ),
            workspaceNotFound: String(
                localized: "rpc.v2.surface.respawn.workspaceNotFound",
                defaultValue: "Workspace not found"
            ),
            noFocusedSurface: String(
                localized: "rpc.v2.surface.respawn.noFocusedSurface",
                defaultValue: "No focused surface"
            ),
            surfaceNotTerminal: String(
                localized: "rpc.v2.surface.respawn.surfaceNotTerminal",
                defaultValue: "Surface is not a terminal"
            )
        )
    }

    /// The byte-faithful twin of `v2BrowserDisabledExternalOpenResult`, mapped onto
    /// the shared ``ControlSurfaceBrowserDisabledOutcome``.
    private func surfaceBrowserDisabledOutcome(
        rawURL: String?,
        url: URL?,
        tabManager: TabManager?
    ) -> ControlSurfaceBrowserDisabledOutcome {
        if let rawURL, url == nil {
            return .invalidURL(rawURL: rawURL)
        }
        guard let url else {
            return .noURL
        }
        guard NSWorkspace.shared.open(url) else {
            return .externalOpenFailed(url: url.absoluteString)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .openedExternally(windowID: windowId, url: url.absoluteString)
    }

    /// Pre-mutation validation for terminal create/split requests aimed at a
    /// remote tmux mirror workspace. The routed tmux command (`split-window` /
    /// `new-window`) cannot honor these options, and reporting "accepted" while
    /// silently dropping them would lie to the caller — so reject BEFORE
    /// routing, while the remote session is still unmutated (an error after the
    /// mutation invites retries that duplicate remote panes). `focus` is
    /// deliberately NOT validated: the socket default is `focus=false` and tmux
    /// always focuses the new remote pane, so it stays best-effort. Shared by
    /// the surface-split/create and pane-create context witnesses.
    func mirrorRoutedUnsupportedOptions(
        insertFirst: Bool = false,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: Double? = nil,
        remotePTYSessionID: String? = nil
    ) -> [String] {
        var unsupported: [String] = []
        if insertFirst { unsupported.append("direction=left/up") }
        if workingDirectory != nil { unsupported.append("working_directory") }
        if initialCommand != nil { unsupported.append("initial_command") }
        if tmuxStartCommand != nil { unsupported.append("tmux_start_command") }
        if !startupEnvironment.isEmpty { unsupported.append("startup_environment") }
        if initialDividerPosition != nil { unsupported.append("initial_divider_position") }
        if remotePTYSessionID != nil { unsupported.append("remote_pty_session_id") }
        return unsupported
    }

    // MARK: - split

    func controlSurfaceSplit(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceSplitInputs
    ) -> ControlSurfaceSplitResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        // The coordinator pre-validates the same token set; if parseSplitDirection
        // ever drifts this still surfaces as the legacy invalid_params error.
        guard let direction = parseSplitDirection(inputs.directionRaw) else {
            return .invalidDirection
        }
        let panelType = inputs.typeRaw.flatMap { surfacePanelType(forRawToken: $0) } ?? .terminal
        if panelType == .agentSession {
            return .agentSessionRejected(typeRawValue: panelType.rawValue)
        }
        let url = inputs.urlRaw.flatMap { URL(string: $0) }
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return .browserDisabled(surfaceBrowserDisabledOutcome(
                rawURL: inputs.urlRaw,
                url: url,
                tabManager: tabManager
            ))
        }

        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let targetSurfaceId: UUID?
        if let requested = inputs.requestedSourceSurfaceID {
            guard ws.panels[requested] != nil else {
                return .requestedSurfaceNotFound(requested)
            }
            targetSurfaceId = requested
        } else {
            targetSurfaceId = ws.focusedPanelId
        }
        guard let targetSurfaceId, ws.panels[targetSurfaceId] != nil else {
            return .noFocusedSurface
        }

        if ws.isRemoteTmuxMirror, panelType == .terminal {
            let unsupported = mirrorRoutedUnsupportedOptions(
                insertFirst: direction.insertFirst,
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                initialDividerPosition: inputs.initialDividerPosition,
                remotePTYSessionID: inputs.remotePTYSessionID
            )
                + inputs.clientUnsupportedRemoteTmuxOptions
            if !unsupported.isEmpty {
                return .mirrorUnsupportedOptions(unsupported)
            }
        }

        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let orientation = direction.orientation
        let insertFirst = direction.insertFirst
        let dividerPosition = inputs.initialDividerPosition.map { CGFloat($0) }
        let newId: UUID?
        if panelType == .browser {
            newId = ws.newBrowserSplit(
                from: targetSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload,
                initialDividerPosition: dividerPosition
            )?.id
        } else {
            switch ws.newTerminalSplitOutcome(
                from: targetSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                focus: focus,
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                initialDividerPosition: dividerPosition,
                remotePTYSessionID: inputs.remotePTYSessionID
            ) {
            case .created(let panel):
                newId = panel.id
            case .routedToRemote:
                return .routedToRemote(
                    windowID: v2ResolveWindowId(tabManager: tabManager),
                    workspaceID: ws.id,
                    typeRawValue: panelType.rawValue
                )
            case .failed:
                newId = nil
            }
        }

        guard let newId else {
            return .createFailed
        }
        return .created(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: ws.paneId(forPanelId: newId)?.id,
            surfaceID: newId,
            typeRawValue: ws.panels[newId]?.panelType.rawValue
        )
    }

    // MARK: - respawn

    func controlSurfaceRespawn(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceRespawnInputs
    ) -> ControlSurfaceRespawnResolution {
        let fallbackTabManager = resolveTabManager(routing: routing)

        let ws: Workspace
        let tabManager: TabManager
        let surfaceId: UUID
        if inputs.hasSurfaceIDParam {
            guard let requestedSurfaceId = inputs.requestedSurfaceID else {
                return .surfaceNotFoundForID(nil)
            }
            guard let located = AppDelegate.shared?.locateSurface(surfaceId: requestedSurfaceId),
                  let locatedWorkspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
                return .surfaceNotFoundForID(requestedSurfaceId)
            }
            ws = locatedWorkspace
            tabManager = located.tabManager
            surfaceId = requestedSurfaceId
        } else {
            guard let fallbackTabManager else {
                return .tabManagerUnavailable
            }
            guard let resolvedWorkspace = resolveSurfaceWorkspace(
                routing: routing,
                tabManager: fallbackTabManager
            ) else {
                return .workspaceNotFound
            }
            guard let focusedSurfaceId = resolvedWorkspace.focusedPanelId else {
                return .noFocusedSurface
            }
            ws = resolvedWorkspace
            tabManager = fallbackTabManager
            surfaceId = focusedSurfaceId
        }
        guard ws.terminalPanel(for: surfaceId) != nil else {
            return .surfaceNotTerminal(surfaceId)
        }

        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let focus: Bool? = inputs.hasFocusParam
            ? v2FocusAllowed(requested: inputs.requestedFocus)
            : nil
        guard let replacementPanel = ws.respawnTerminalSurface(
            panelId: surfaceId,
            command: inputs.command,
            workingDirectory: inputs.workingDirectory,
            tmuxStartCommand: inputs.tmuxStartCommand,
            focus: focus
        ) else {
            return .respawnFailed(surfaceId)
        }
        return .respawned(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            typeRawValue: replacementPanel.panelType.rawValue
        )
    }

    // MARK: - create

    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        let panelType = inputs.typeRaw.flatMap { surfacePanelType(forRawToken: $0) } ?? .terminal

        var providerID: AgentSessionProviderID = .codex
        var rendererKind: AgentSessionRendererKind = .react
        if panelType == .agentSession {
            if let providerRaw = inputs.providerRaw {
                switch v2NormalizedToken(providerRaw) {
                case "codex": providerID = .codex
                case "claude", "claudecode": providerID = .claude
                case "opencode": providerID = .opencode
                default: return .invalidProvider(rawValue: providerRaw)
                }
            }
            if let rendererRaw = inputs.rendererRaw {
                switch v2NormalizedToken(rendererRaw) {
                case "react": rendererKind = .react
                case "solid": rendererKind = .solid
                default: return .invalidRenderer(rawValue: rendererRaw)
                }
            }
        }

        let placement = resolveControlPlacement(inputs.placementRaw)
        if case .invalid(let raw) = placement {
            return .invalidPlacement(rawValue: raw)
        }
        if case .dock = placement, !RightSidebarMode.dock.isAvailable() {
            return .dockUnavailable(message: dockUnavailableMessage())
        }

        let url = inputs.urlRaw.flatMap { URL(string: $0) }
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return .browserDisabled(surfaceBrowserDisabledOutcome(
                rawURL: inputs.urlRaw,
                url: url,
                tabManager: tabManager
            ))
        }

        if case .dock = placement {
            return dockSurfaceCreate(
                tabManager: tabManager,
                panelType: panelType,
                url: url,
                inputs: inputs
            )
        }

        guard let ws = resolveSurfaceCreateWorkspace(
            routing: routing,
            tabManager: tabManager
        ) else {
            return .workspaceNotFound
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let paneId: PaneID? = {
            if let paneUUID = inputs.requestedPaneID {
                return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
            }
            return ws.bonsplitController.focusedPaneId
        }()
        guard let paneId else {
            return .paneNotFound
        }

        if ws.isRemoteTmuxMirror, panelType == .terminal {
            let unsupported = mirrorRoutedUnsupportedOptions(
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                remotePTYSessionID: inputs.remotePTYSessionID
            )
            if !unsupported.isEmpty {
                return .mirrorUnsupportedOptions(unsupported)
            }
        }

        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let newPanelId: UUID?
        if panelType == .browser {
            newPanelId = ws.newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: focus,
                creationPolicy: .automationPreload
            )?.id
        } else if panelType == .agentSession {
            newPanelId = ws.newAgentSessionSurface(
                inPane: paneId,
                providerID: providerID,
                rendererKind: rendererKind,
                workingDirectory: inputs.workingDirectory,
                focus: focus
            )?.id
        } else {
            switch ws.newTerminalSurfaceOutcome(
                inPane: paneId,
                focus: focus,
                workingDirectory: inputs.workingDirectory,
                initialCommand: inputs.initialCommand,
                tmuxStartCommand: inputs.tmuxStartCommand,
                startupEnvironment: inputs.startupEnvironment,
                remotePTYSessionID: inputs.remotePTYSessionID,
                inheritWorkingDirectoryFallback: true
            ) {
            case .created(let panel):
                newPanelId = panel.id
            case .routedToRemote:
                return .routedToRemote(
                    windowID: v2ResolveWindowId(tabManager: tabManager),
                    workspaceID: ws.id,
                    typeRawValue: panelType.rawValue
                )
            case .failed:
                newPanelId = nil
            }
        }

        guard let newPanelId else {
            return .createFailed
        }
        return .created(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: paneId.id,
            surfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }

    // MARK: - close

    func controlSurfaceClose(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceCloseResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        if let windowDock = windowDockForRouting(routing, tabManager: tabManager) {
            let resolved = resolvedWindowDockSurfaceId(
                explicitSurfaceID: surfaceID,
                hasSurfaceIDParam: false,
                routing: routing,
                dock: windowDock
            )
            guard let surfaceId = resolved.surfaceID else {
                return .noFocusedSurface
            }
            guard windowDock.containsPanel(surfaceId) else {
                return .closeFailed(surfaceId)
            }
            guard windowDock.closePanel(surfaceId, force: true) else {
                return .closeFailed(surfaceId)
            }
            AppDelegate.shared?.notificationStore?.clearNotifications(
                forTabId: windowDock.workspaceId,
                surfaceId: surfaceId
            )
            return .closed(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceId
            )
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let surfaceId = resolvedSurfaceIdForClose(
            explicitSurfaceID: surfaceID,
            routing: routing,
            fallbackWorkspace: ws
        ) else {
            return .noFocusedSurface
        }
        if let windowDock = windowDockContainingPanel(surfaceId) {
            guard windowDock.closePanel(surfaceId, force: true) else {
                return .closeFailed(surfaceId)
            }
            AppDelegate.shared?.notificationStore?.clearNotifications(
                forTabId: windowDock.workspaceId,
                surfaceId: surfaceId
            )
            return .closed(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: windowDock.workspaceId,
                surfaceID: surfaceId
            )
        } else if ws.containsDockPanel(surfaceId) {
            guard ws.closeDockPanelAndClearNotifications(surfaceId, force: true) else {
                return .closeFailed(surfaceId)
            }
            return .closed(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: surfaceId
            )
        }
        guard ws.panels[surfaceId] != nil else {
            return .surfaceNotFound(surfaceId)
        }
        if ws.panels.count <= 1 {
            return .lastSurface
        }
        // Socket API must be non-interactive: bypass close-confirmation gating.
        guard controlCloseSurfaceRecordingHistory(in: ws, surfaceId: surfaceId, force: true) else {
            return .closeFailed(surfaceId)
        }
        return .closed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    /// The byte-faithful twin of the file-private `closeSurfaceRecordingHistory`,
    /// re-declared here because `private` is file-scoped and the original lives in
    /// `TerminalController.swift`.
    @discardableResult
    private func controlCloseSurfaceRecordingHistory(
        in workspace: Workspace,
        surfaceId: UUID,
        force: Bool
    ) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            if force {
                return workspace.requestNonInteractiveCloseTabRecordingHistory(tabId)
            }
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }
        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    /// The byte-faithful twin of `v2PanelType`'s token mapping (the `v2PanelType`
    /// helper takes `[String: Any]`; the coordinator passes the raw token, so this
    /// maps a token directly, identical to the legacy switch).
    private func surfacePanelType(forRawToken raw: String) -> PanelType? {
        switch v2NormalizedToken(raw) {
        case "terminal": return .terminal
        case "browser": return .browser
        case "markdown": return .markdown
        case "filepreview": return .filePreview
        case "rightsidebartool": return .rightSidebarTool
        case "agentsession": return .agentSession
        default: return nil
        }
    }
}
