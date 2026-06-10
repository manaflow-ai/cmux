import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 surface lifecycle methods
extension TerminalController {
    @MainActor
    @discardableResult
    func closeSurfaceRecordingHistory(in workspace: Workspace, surfaceId: UUID, force: Bool) -> Bool {
        if let tabId = workspace.surfaceIdFromPanelId(surfaceId) {
            return workspace.requestCloseTabRecordingHistory(tabId, force: force)
        }

        workspace.markCloseHistoryEligible(panelId: surfaceId)
        return workspace.closePanel(surfaceId, force: force)
    }

    func v2ResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let wsId = v2UUID(params, "workspace_id") {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = v2UUID(params, "surface_id")
            ?? v2UUID(params, "terminal_id")
            ?? v2UUID(params, "tab_id") {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = v2UUID(params, "pane_id"),
           let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    func v2SurfaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Map panel_id -> pane_id and index/selection within that pane.
            var paneByPanelId: [UUID: UUID] = [:]
            var indexInPaneByPanelId: [UUID: Int] = [:]
            var selectedInPaneByPanelId: [UUID: Bool] = [:]
            for paneId in ws.bonsplitController.allPaneIds {
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let selected = ws.bonsplitController.selectedTab(inPane: paneId)
                for (idx, tab) in tabs.enumerated() {
                    guard let panelId = ws.panelIdFromSurfaceId(tab.id) else { continue }
                    paneByPanelId[panelId] = paneId.id
                    indexInPaneByPanelId[panelId] = idx
                    selectedInPaneByPanelId[panelId] = (tab.id == selected?.id)
                }
            }

            let focusedSurfaceId = ws.focusedPanelId
            let panels = orderedPanels(in: ws)
            let surfaces: [[String: Any]] = panels.enumerated().map { index, panel in
                let paneUUID = paneByPanelId[panel.id]
                var item: [String: Any] = [
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "type": panel.panelType.rawValue,
                    "title": ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    "focused": panel.id == focusedSurfaceId,
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                    "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id])
                ]
                if let browserPanel = panel as? BrowserPanel {
                    item["developer_tools_visible"] = browserPanel.isDeveloperToolsVisible()
                }
                if let terminalPanel = panel as? TerminalPanel {
                    item["requested_working_directory"] = v2OrNull(v2NonEmptyString(terminalPanel.requestedWorkingDirectory))
                    item["initial_command"] = v2OrNull(v2NonEmptyString(terminalPanel.surface.debugInitialCommand()))
                    item["tmux_start_command"] = v2OrNull(v2NonEmptyString(terminalPanel.surface.debugTmuxStartCommand()))
                    item["resume_binding"] = v2SurfaceResumeBindingPayload(ws.surfaceResumeBinding(panelId: panel.id))
                }
                return item
            }

            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": surfaces
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        var out = payload
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        out["window_id"] = v2OrNull(windowId?.uuidString)
        out["window_ref"] = v2Ref(kind: .window, uuid: windowId)
        return .ok(out)
    }

    func v2SurfaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            // Focus can be transiently nil during startup/reparenting; fall back to first
            // ordered panel so callers always get a usable current surface.
            let surfaceId = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
            let paneId = surfaceId.flatMap { ws.paneId(forPanelId: $0)?.id }
            let windowId = v2ResolveWindowId(tabManager: tabManager)

            payload = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneId?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneId),
                "surface_id": v2OrNull(surfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "surface_type": v2OrNull(surfaceId.flatMap { ws.panels[$0]?.panelType.rawValue })
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    func v2SurfaceFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }

            // Make sure the workspace is selected so focus effects apply to the visible UI.
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            ws.focusPanel(surfaceId)
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    private func v2AgentSessionOptions(params: [String: Any]) -> (
        providerID: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind,
        error: V2CallResult?
    ) {
        let providerRaw = v2String(params, "provider_id") ?? v2String(params, "provider")
        let rendererRaw = v2String(params, "renderer_kind") ?? v2String(params, "renderer")

        let providerID: AgentSessionProviderID
        if let providerRaw {
            switch v2NormalizedToken(providerRaw) {
            case "codex":
                providerID = .codex
            case "claude", "claudecode":
                providerID = .claude
            case "opencode":
                providerID = .opencode
            default:
                return (
                    .codex,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid provider (codex|claude|opencode)",
                        data: ["provider": providerRaw]
                    )
                )
            }
        } else {
            providerID = .codex
        }

        let rendererKind: AgentSessionRendererKind
        if let rendererRaw {
            switch v2NormalizedToken(rendererRaw) {
            case "react":
                rendererKind = .react
            case "solid":
                rendererKind = .solid
            default:
                return (
                    providerID,
                    .react,
                    .err(
                        code: "invalid_params",
                        message: "Invalid renderer (react|solid)",
                        data: ["renderer": rendererRaw]
                    )
                )
            }
        } else {
            rendererKind = .react
        }

        return (providerID, rendererKind, nil)
    }

    func v2SurfaceSplit(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let directionStr = v2String(params, "direction"),
              let direction = parseSplitDirection(directionStr) else {
            return .err(code: "invalid_params", message: "Missing or invalid direction (left|right|up|down)", data: nil)
        }
        let panelType = v2PanelType(params, "type") ?? .terminal
        if panelType == .agentSession {
            return .err(
                code: "invalid_params",
                message: "agent-session is only supported by surface.create",
                data: ["type": panelType.rawValue]
            )
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let initialCommand = v2OptionalTrimmedRawString(params, "initial_command")
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command")
        let remotePTYSessionID = v2OptionalTrimmedRawString(params, "remote_pty_session_id")
        let startupEnvironment = v2TrimmedStringMap(params, keys: ["startup_environment", "initial_env"])
        let parsedInitialDivider = v2InitialDividerPosition(params)
        if let error = parsedInitialDivider.error {
            return error
        }
        let initialDividerPosition = parsedInitialDivider.value
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create split", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let requestedSurfaceId: UUID? = v2UUID(params, "surface_id")
            let targetSurfaceId: UUID?
            if let requestedSurfaceId {
                guard ws.panels[requestedSurfaceId] != nil else {
                    result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": requestedSurfaceId.uuidString])
                    return
                }
                targetSurfaceId = requestedSurfaceId
            } else {
                targetSurfaceId = ws.focusedPanelId
            }
            guard let targetSurfaceId, ws.panels[targetSurfaceId] != nil else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            let orientation = direction.orientation
            let insertFirst = direction.insertFirst
            let newId: UUID?
            if panelType == .browser {
                newId = ws.newBrowserSplit(
                    from: targetSurfaceId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload,
                    initialDividerPosition: initialDividerPosition.map { CGFloat($0) }
                )?.id
            } else {
                newId = tabManager.newSplit(
                    tabId: ws.id,
                    surfaceId: targetSurfaceId,
                    direction: direction,
                    focus: focus,
                    workingDirectory: workingDirectory,
                    initialCommand: initialCommand,
                    tmuxStartCommand: tmuxStartCommand,
                    startupEnvironment: startupEnvironment,
                    initialDividerPosition: initialDividerPosition.map { CGFloat($0) },
                    remotePTYSessionID: remotePTYSessionID
                )
            }

            if let newId {
                let paneUUID = ws.paneId(forPanelId: newId)?.id
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": v2OrNull(paneUUID?.uuidString),
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "surface_id": newId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: newId),
                    "type": v2OrNull(ws.panels[newId]?.panelType.rawValue)
                ])
            } else {
                result = .err(code: "internal_error", message: "Failed to create split", data: nil)
            }
        }
        return result
    }

    func v2SurfaceRespawn(params: [String: Any]) -> V2CallResult {
        let fallbackTabManager = v2ResolveTabManager(params: params)

        let command = v2OptionalTrimmedRawString(params, "command")
            ?? v2OptionalTrimmedRawString(params, "initial_command")
            ?? "exec ${SHELL:-/bin/zsh} -l"
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command") ?? command
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let focus: Bool?
        if v2HasNonNullParam(params, "focus") {
            guard let parsedFocus = v2Bool(params, "focus") else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        localized: "rpc.v2.surface.respawn.invalidFocus",
                        defaultValue: "Missing or invalid focus"
                    ),
                    data: nil
                )
            }
            focus = v2FocusAllowed(requested: parsedFocus)
        } else {
            focus = nil
        }

        var result: V2CallResult = .err(
            code: "internal_error",
            message: String(
                localized: "rpc.v2.surface.respawn.failed",
                defaultValue: "Failed to respawn surface"
            ),
            data: nil
        )
        v2MainSync {
            let ws: Workspace
            let tabManager: TabManager
            let surfaceId: UUID
            if v2HasNonNullParam(params, "surface_id") {
                guard let requestedSurfaceId = v2UUID(params, "surface_id") else {
                    result = .err(
                        code: "not_found",
                        message: String(
                            localized: "rpc.v2.surface.respawn.surfaceNotFoundForId",
                            defaultValue: "Surface not found for the given surface_id"
                        ),
                        data: nil
                    )
                    return
                }
                guard let located = AppDelegate.shared?.locateSurface(surfaceId: requestedSurfaceId),
                      let locatedWorkspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }) else {
                    result = .err(
                        code: "not_found",
                        message: String(
                            localized: "rpc.v2.surface.respawn.surfaceNotFoundForId",
                            defaultValue: "Surface not found for the given surface_id"
                        ),
                        data: ["surface_id": requestedSurfaceId.uuidString]
                    )
                    return
                }
                ws = locatedWorkspace
                tabManager = located.tabManager
                surfaceId = requestedSurfaceId
            } else {
                guard let fallbackTabManager = fallbackTabManager else {
                    result = .err(
                        code: "unavailable",
                        message: String(
                            localized: "rpc.v2.surface.respawn.tabManagerUnavailable",
                            defaultValue: "Unable to access the target workspace"
                        ),
                        data: nil
                    )
                    return
                }
                guard let resolvedWorkspace = v2ResolveWorkspace(params: params, tabManager: fallbackTabManager) else {
                    result = .err(
                        code: "not_found",
                        message: String(
                            localized: "rpc.v2.surface.respawn.workspaceNotFound",
                            defaultValue: "Workspace not found"
                        ),
                        data: nil
                    )
                    return
                }
                guard let focusedSurfaceId = resolvedWorkspace.focusedPanelId else {
                    result = .err(
                        code: "not_found",
                        message: String(
                            localized: "rpc.v2.surface.respawn.noFocusedSurface",
                            defaultValue: "No focused surface"
                        ),
                        data: nil
                    )
                    return
                }
                ws = resolvedWorkspace
                tabManager = fallbackTabManager
                surfaceId = focusedSurfaceId
            }
            guard ws.terminalPanel(for: surfaceId) != nil else {
                result = .err(
                    code: "invalid_params",
                    message: String(
                        localized: "rpc.v2.surface.respawn.surfaceNotTerminal",
                        defaultValue: "Surface is not a terminal"
                    ),
                    data: ["surface_id": surfaceId.uuidString]
                )
                return
            }

            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            guard let replacementPanel = ws.respawnTerminalSurface(
                panelId: surfaceId,
                command: command,
                workingDirectory: workingDirectory,
                tmuxStartCommand: tmuxStartCommand,
                focus: focus
            ) else {
                result = .err(
                    code: "internal_error",
                    message: String(
                        localized: "rpc.v2.surface.respawn.failed",
                        defaultValue: "Failed to respawn surface"
                    ),
                    data: ["surface_id": surfaceId.uuidString]
                )
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "type": replacementPanel.panelType.rawValue,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2SurfaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let panelType = v2PanelType(params, "type") ?? .terminal
        let agentOptions = v2AgentSessionOptions(params: params)
        if panelType == .agentSession, let error = agentOptions.error {
            return error
        }
        let urlStr = v2String(params, "url")
        let url = urlStr.flatMap { URL(string: $0) }
        let workingDirectory = v2OptionalTrimmedRawString(params, "working_directory")
        let initialCommand = v2OptionalTrimmedRawString(params, "initial_command")
        let tmuxStartCommand = v2OptionalTrimmedRawString(params, "tmux_start_command")
        let remotePTYSessionID = v2OptionalTrimmedRawString(params, "remote_pty_session_id")
        let startupEnvironment = v2TrimmedStringMap(params, keys: ["startup_environment", "initial_env"])
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let paneUUID = v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()

            guard let paneId else {
                result = .err(code: "not_found", message: "Pane not found", data: nil)
                return
            }

            let newPanelId: UUID?
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
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
                    providerID: agentOptions.providerID,
                    rendererKind: agentOptions.rendererKind,
                    workingDirectory: workingDirectory,
                    focus: focus
                )?.id
            } else {
                newPanelId = ws.newTerminalSurface(
                    inPane: paneId,
                    focus: focus,
                    workingDirectory: workingDirectory,
                    initialCommand: initialCommand,
                    tmuxStartCommand: tmuxStartCommand,
                    startupEnvironment: startupEnvironment,
                    remotePTYSessionID: remotePTYSessionID
                )?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create surface", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surface_id": newPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ])
        }
        return result
    }

    func v2SurfaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to close surface", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }

            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            // Socket API must be non-interactive: bypass close-confirmation gating.
            let ok = closeSurfaceRecordingHistory(in: ws, surfaceId: surfaceId, force: true)
            result = ok
                ? .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
                : .err(code: "internal_error", message: "Failed to close surface", data: ["surface_id": surfaceId.uuidString])
        }
        return result
    }

    func v2SurfaceMove(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let requestedPaneUUID = v2UUID(params, "pane_id")
        let requestedWorkspaceUUID = v2UUID(params, "workspace_id")
        let requestedWindowUUID = v2UUID(params, "window_id")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let explicitIndex = v2Int(params, "index")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        let anchorCount = (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if anchorCount > 1 {
            return .err(code: "invalid_params", message: "Specify at most one of before_surface_id or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared else {
                result = .err(code: "unavailable", message: "AppDelegate not available", data: nil)
                return
            }

            guard let source = app.locateSurface(surfaceId: surfaceId),
                  let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let sourcePane = sourceWorkspace.paneId(forPanelId: surfaceId)
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)

            var targetWindowId = source.windowId
            var targetTabManager = source.tabManager
            var targetWorkspace = sourceWorkspace
            var targetPane = sourcePane ?? sourceWorkspace.bonsplitController.focusedPaneId ?? sourceWorkspace.bonsplitController.allPaneIds.first
            var targetIndex = explicitIndex

            if let anchorSurfaceId = beforeSurfaceId ?? afterSurfaceId {
                guard let anchor = app.locateSurface(surfaceId: anchorSurfaceId),
                      let anchorWorkspace = anchor.tabManager.tabs.first(where: { $0.id == anchor.workspaceId }),
                      let anchorPane = anchorWorkspace.paneId(forPanelId: anchorSurfaceId),
                      let anchorIndex = anchorWorkspace.indexInPane(forPanelId: anchorSurfaceId) else {
                    result = .err(code: "not_found", message: "Anchor surface not found", data: ["surface_id": anchorSurfaceId.uuidString])
                    return
                }
                targetWindowId = anchor.windowId
                targetTabManager = anchor.tabManager
                targetWorkspace = anchorWorkspace
                targetPane = anchorPane
                targetIndex = (beforeSurfaceId != nil) ? anchorIndex : (anchorIndex + 1)
            } else if let paneUUID = requestedPaneUUID {
                guard let located = v2LocatePane(paneUUID) else {
                    result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
                targetWindowId = located.windowId
                targetTabManager = located.tabManager
                targetWorkspace = located.workspace
                targetPane = located.paneId
            } else if let workspaceUUID = requestedWorkspaceUUID {
                guard let tm = app.tabManagerFor(tabId: workspaceUUID),
                      let ws = tm.tabs.first(where: { $0.id == workspaceUUID }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceUUID.uuidString])
                    return
                }
                targetTabManager = tm
                targetWorkspace = ws
                targetWindowId = app.windowId(for: tm) ?? targetWindowId
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            } else if let windowUUID = requestedWindowUUID {
                guard let tm = app.tabManagerFor(windowId: windowUUID) else {
                    result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWindowId = windowUUID
                targetTabManager = tm
                guard let selectedWorkspaceId = tm.selectedTabId,
                      let ws = tm.tabs.first(where: { $0.id == selectedWorkspaceId }) else {
                    result = .err(code: "not_found", message: "Target window has no selected workspace", data: ["window_id": windowUUID.uuidString])
                    return
                }
                targetWorkspace = ws
                targetPane = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let destinationPane = targetPane else {
                result = .err(code: "not_found", message: "No destination pane", data: nil)
                return
            }

            if targetWorkspace.id == sourceWorkspace.id {
                guard sourceWorkspace.moveSurface(panelId: surfaceId, toPane: destinationPane, atIndex: targetIndex, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to move surface", data: nil)
                    return
                }
                result = .ok([
                    "window_id": targetWindowId.uuidString,
                    "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                    "workspace_id": targetWorkspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                    "pane_id": destinationPane.id.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
                ])
                return
            }

            guard let transfer = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach surface", data: nil)
                return
            }

            if targetWorkspace.attachDetachedSurface(transfer, inPane: destinationPane, atIndex: targetIndex, focus: focus) == nil {
                // Roll back to source workspace if attach fails.
                let rollbackPane = sourcePane.flatMap { sp in sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == sp }) }
                    ?? sourceWorkspace.bonsplitController.focusedPaneId
                    ?? sourceWorkspace.bonsplitController.allPaneIds.first
                if let rollbackPane {
                    _ = sourceWorkspace.attachDetachedSurface(transfer, inPane: rollbackPane, atIndex: sourceIndex, focus: focus)
                }
                result = .err(code: "internal_error", message: "Failed to attach surface to destination", data: nil)
                return
            }

            if focus {
                _ = app.focusMainWindow(windowId: targetWindowId)
                setActiveTabManager(targetTabManager)
                targetTabManager.selectWorkspace(targetWorkspace)
            }

            result = .ok([
                "window_id": targetWindowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: targetWindowId),
                "workspace_id": targetWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: targetWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }

    func v2SurfaceReorder(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        let index = v2Int(params, "index")
        let beforeSurfaceId = v2UUID(params, "before_surface_id")
        let afterSurfaceId = v2UUID(params, "after_surface_id")
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
        let targetCount = (index != nil ? 1 : 0) + (beforeSurfaceId != nil ? 1 : 0) + (afterSurfaceId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(code: "invalid_params", message: "Specify exactly one of index, before_surface_id, or after_surface_id", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
        v2MainSync {
            guard let app = AppDelegate.shared,
                  let located = app.locateSurface(surfaceId: surfaceId),
                  let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                  let sourcePane = ws.paneId(forPanelId: surfaceId) else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }

            let targetIndex: Int
            if let index {
                targetIndex = index
            } else if let beforeSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex
            } else if let afterSurfaceId {
                guard let anchorPane = ws.paneId(forPanelId: afterSurfaceId),
                      anchorPane == sourcePane,
                      let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceId) else {
                    result = .err(code: "invalid_params", message: "Anchor surface must be in the same pane", data: nil)
                    return
                }
                targetIndex = anchorIndex + 1
            } else {
                result = .err(code: "invalid_params", message: "Missing reorder target", data: nil)
                return
            }

            guard ws.reorderSurface(panelId: surfaceId, toIndex: targetIndex, focus: focus) else {
                result = .err(code: "internal_error", message: "Failed to reorder surface", data: nil)
                return
            }

            result = .ok([
                "window_id": located.windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: located.windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }

        return result
    }
    func v2SurfaceRefresh(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var result: V2CallResult = .ok(["refreshed": 0])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            var refreshedCount = 0
            for panel in ws.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                    refreshedCount += 1
                }
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "refreshed": refreshedCount])
        }
        return result
    }

    func v2SurfaceHealth(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let panels = orderedPanels(in: ws)
            let items: [[String: Any]] = panels.enumerated().map { index, panel in
                var inWindow: Any = NSNull()
                if let tp = panel as? TerminalPanel {
                    inWindow = tp.surface.isViewInWindow
                } else if let bp = panel as? BrowserPanel {
                    inWindow = bp.webView.window != nil
                }
                return [
                    "index": index,
                    "id": panel.id.uuidString,
                    "ref": v2Ref(kind: .surface, uuid: panel.id),
                    "type": panel.panelType.rawValue,
                    "in_window": inWindow
                ]
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surfaces": items,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

}
