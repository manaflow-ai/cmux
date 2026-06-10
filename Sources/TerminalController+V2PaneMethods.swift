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


// MARK: - V2 pane methods
extension TerminalController {
    func v2PaneList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let focusedPaneId = ws.bonsplitController.focusedPaneId
            let snapshot = ws.bonsplitController.layoutSnapshot()
            let geometryByPaneId = Dictionary(
                snapshot.panes.map { ($0.paneId, $0.frame) },
                uniquingKeysWith: { first, _ in first }
            )

            let panes: [[String: Any]] = ws.bonsplitController.allPaneIds.enumerated().map { index, paneId in
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let surfaceUUIDs: [UUID] = tabs.compactMap { ws.panelIdFromSurfaceId($0.id) }
                let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
                let selectedSurfaceUUID = selectedTab.flatMap { ws.panelIdFromSurfaceId($0.id) }

                var dict: [String: Any] = [
                    "id": paneId.id.uuidString,
                    "ref": v2Ref(kind: .pane, uuid: paneId.id),
                    "index": index,
                    "focused": paneId == focusedPaneId,
                    "surface_ids": surfaceUUIDs.map { $0.uuidString },
                    "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                    "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                    "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                    "surface_count": surfaceUUIDs.count
                ]

                if let frame = geometryByPaneId[paneId.id.uuidString] {
                    dict["pixel_frame"] = [
                        "x": frame.x, "y": frame.y,
                        "width": frame.width, "height": frame.height
                    ]
                }

                // Get terminal grid size from the selected surface
                if let panelUUID = selectedSurfaceUUID,
                   let panel = ws.panels[panelUUID] as? TerminalPanel,
                   panel.surface.hasLiveSurface,
                   let ghosttySurface = panel.surface.surface {
                    let size = ghostty_surface_size(ghosttySurface)
                    if size.columns > 0 && size.rows > 0 {
                        dict["columns"] = Int(size.columns)
                        dict["rows"] = Int(size.rows)
                        dict["cell_width_px"] = Int(size.cell_width_px)
                        dict["cell_height_px"] = Int(size.cell_height_px)
                    }
                }

                return dict
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            var payloadDict: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "panes": panes,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
            payloadDict["container_frame"] = [
                "width": snapshot.containerFrame.width,
                "height": snapshot.containerFrame.height
            ]
            payload = payloadDict
        }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }
    func v2PaneFocus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let paneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }
            ws.bonsplitController.focusPane(paneId)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "pane_id": paneId.id.uuidString, "pane_ref": v2Ref(kind: .pane, uuid: paneId.id)])
        }
        return result
    }

    func v2PaneSurfaces(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

            let paneUUID = v2UUID(params, "pane_id")
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()
            guard let paneId else { return }

            let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
            let tabs = ws.bonsplitController.tabs(inPane: paneId)

            let surfaces: [[String: Any]] = tabs.enumerated().map { index, tab in
                let panelId = ws.panelIdFromSurfaceId(tab.id)
                let panel = panelId.flatMap { ws.panels[$0] }
                return [
                    "id": v2OrNull(panelId?.uuidString),
                    "ref": v2Ref(kind: .surface, uuid: panelId),
                    "index": index,
                    "title": tab.title,
                    "type": v2OrNull(panel?.panelType.rawValue),
                    "selected": tab.id == selectedTab?.id
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surfaces": surfaces,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        guard let payload else {
            return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
        }
        return .ok(payload)
    }
    func v2PaneCreate(params: [String: Any]) -> V2CallResult {
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
        let startupEnvironment = v2TrimmedStringMap(params, keys: ["startup_environment", "initial_env"])
        if panelType == .browser, BrowserAvailabilitySettings.isDisabled() {
            return v2BrowserDisabledExternalOpenResult(rawURL: urlStr, url: url, tabManager: tabManager)
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst
        let parsedInitialDivider = v2InitialDividerPosition(params)
        if let error = parsedInitialDivider.error {
            return error
        }
        let initialDividerPosition = parsedInitialDivider.value

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create pane", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)
            let requestedPanelId = v2String(params, "surface_id").flatMap(UUID.init(uuidString:))
            guard let sourcePanelId = requestedPanelId ?? ws.focusedPanelId,
                  ws.panels[sourcePanelId] != nil else {
                result = .err(code: "not_found", message: "No source surface to split", data: nil)
                return
            }

            let newPanelId: UUID?
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            if panelType == .browser {
                newPanelId = ws.newBrowserSplit(
                    from: sourcePanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload,
                    initialDividerPosition: initialDividerPosition.map { CGFloat($0) }
                )?.id
            } else {
                newPanelId = ws.newTerminalSplit(
                    from: sourcePanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: focus,
                    workingDirectory: workingDirectory,
                    initialCommand: initialCommand,
                    tmuxStartCommand: tmuxStartCommand,
                    startupEnvironment: startupEnvironment,
                    initialDividerPosition: initialDividerPosition.map { CGFloat($0) }
                )?.id
            }

            guard let newPanelId else {
                result = .err(code: "internal_error", message: "Failed to create pane", data: nil)
                return
            }
            let paneUUID = ws.paneId(forPanelId: newPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "surface_id": newPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
                "type": panelType.rawValue
            ])
        }
        return result
    }

    func v2PaneResize(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let absoluteAxis = v2String(params, "absolute_axis")?.lowercased()
        let targetPixels = v2Double(params, "target_pixels")
        let directionRaw = (v2String(params, "direction") ?? "").lowercased()
        let amount = v2Int(params, "amount") ?? 1
        let direction = V2PaneResizeDirection(rawValue: directionRaw)
        let hasAbsoluteIntent = params.keys.contains("absolute_axis") || params.keys.contains("target_pixels")
        if hasAbsoluteIntent {
            guard let absoluteAxis,
                  absoluteAxis == "horizontal" || absoluteAxis == "vertical" else {
                return .err(code: "invalid_params", message: "absolute_axis must be 'horizontal' or 'vertical'", data: nil)
            }
            guard let targetPixels, targetPixels > 0 else {
                return .err(code: "invalid_params", message: "target_pixels must be > 0", data: nil)
            }
        } else {
            guard direction != nil, amount > 0 else {
                return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
            }
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to resize pane", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let paneUUID = v2UUID(params, "pane_id") ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard ws.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                return
            }

            let tree = ws.bonsplitController.treeSnapshot()
            var candidates: [V2PaneResizeCandidate] = []
            let trace = v2PaneResizeCollectCandidates(
                node: tree,
                targetPaneId: paneUUID.uuidString,
                candidates: &candidates
            )
            guard trace.containsTarget else {
                result = .err(code: "not_found", message: "Pane not found in split tree", data: ["pane_id": paneUUID.uuidString])
                return
            }

            if let absoluteAxis,
               let targetPixels,
               let absoluteResize = v2SetAbsolutePaneSize(
                    workspace: ws,
                    paneUUID: paneUUID,
                    axis: absoluteAxis,
                    targetPixels: CGFloat(targetPixels)
               ) {
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                result = .ok([
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "pane_id": paneUUID.uuidString,
                    "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                    "split_id": absoluteResize.splitId.uuidString,
                    "absolute_axis": absoluteAxis,
                    "target_pixels": targetPixels,
                    "old_divider_position": absoluteResize.oldPosition,
                    "new_divider_position": absoluteResize.newPosition
                ])
                return
            } else if absoluteAxis != nil || targetPixels != nil {
                result = .err(
                    code: "invalid_state",
                    message: "No split ancestor for absolute pane resize",
                    data: ["pane_id": paneUUID.uuidString, "absolute_axis": v2OrNull(absoluteAxis)]
                )
                return
            }

            guard let direction else {
                result = .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
                return
            }

            let orientationMatches = candidates.filter { $0.orientation == direction.splitOrientation }
            guard !orientationMatches.isEmpty else {
                result = .err(
                    code: "invalid_state",
                    message: "No \(direction.splitOrientation) split ancestor for pane",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            guard let candidate = orientationMatches.first(where: { $0.paneInFirstChild == direction.requiresPaneInFirstChild }) else {
                result = .err(
                    code: "invalid_state",
                    message: "Pane has no adjacent border in direction \(direction.rawValue)",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
                return
            }

            let delta = CGFloat(amount) / candidate.axisPixels
            let requested = candidate.dividerPosition + (direction.dividerDeltaSign * delta)
            let clamped = min(max(requested, 0.1), 0.9)
            guard ws.bonsplitController.setDividerPosition(clamped, forSplit: candidate.splitId, fromExternal: true) else {
                result = .err(
                    code: "internal_error",
                    message: "Failed to set split divider position",
                    data: ["split_id": candidate.splitId.uuidString]
                )
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneUUID.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "split_id": candidate.splitId.uuidString,
                "direction": direction.rawValue,
                "amount": amount,
                "old_divider_position": candidate.dividerPosition,
                "new_divider_position": clamped
            ])
        }
        return result
    }

    func v2PaneSwap(params: [String: Any]) -> V2CallResult {
        guard let sourcePaneUUID = v2UUID(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }
        if sourcePaneUUID == targetPaneUUID {
            return .err(code: "invalid_params", message: "pane_id and target_pane_id must be different", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to swap panes", data: nil)
        v2MainSync {
            guard let located = v2LocatePane(sourcePaneUUID) else {
                result = .err(code: "not_found", message: "Source pane not found", data: ["pane_id": sourcePaneUUID.uuidString])
                return
            }
            guard let targetPane = located.workspace.bonsplitController.allPaneIds.first(where: { $0.id == targetPaneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found in source workspace", data: ["target_pane_id": targetPaneUUID.uuidString])
                return
            }
            let workspace = located.workspace
            let sourcePane = located.paneId

            guard let selectedSourceTab = workspace.bonsplitController.selectedTab(inPane: sourcePane),
                  let selectedTargetTab = workspace.bonsplitController.selectedTab(inPane: targetPane),
                  let sourceSurfaceId = workspace.panelIdFromSurfaceId(selectedSourceTab.id),
                  let targetSurfaceId = workspace.panelIdFromSurfaceId(selectedTargetTab.id) else {
                result = .err(code: "invalid_state", message: "Both panes must have a selected surface", data: nil)
                return
            }

            // Keep pane identities stable during swap when one side has a single surface.
            var sourcePlaceholder: UUID?
            var targetPlaceholder: UUID?
            if workspace.bonsplitController.tabs(inPane: sourcePane).count <= 1 {
                sourcePlaceholder = workspace.newTerminalSurface(inPane: sourcePane, focus: false)?.id
                if sourcePlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create source placeholder surface", data: nil)
                    return
                }
            }
            if workspace.bonsplitController.tabs(inPane: targetPane).count <= 1 {
                targetPlaceholder = workspace.newTerminalSurface(inPane: targetPane, focus: false)?.id
                if targetPlaceholder == nil {
                    result = .err(code: "internal_error", message: "Failed to create target placeholder surface", data: nil)
                    return
                }
            }

            guard workspace.moveSurface(panelId: sourceSurfaceId, toPane: targetPane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving source surface into target pane", data: nil)
                return
            }
            guard workspace.moveSurface(panelId: targetSurfaceId, toPane: sourcePane, focus: false) else {
                result = .err(code: "internal_error", message: "Failed moving target surface into source pane", data: nil)
                return
            }

            if let sourcePlaceholder {
                _ = workspace.closePanel(sourcePlaceholder, force: true)
            }
            if let targetPlaceholder {
                _ = workspace.closePanel(targetPlaceholder, force: true)
            }

            if focus {
                workspace.bonsplitController.focusPane(targetPane)
            }
            let windowId = located.windowId
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "target_pane_id": targetPane.id.uuidString,
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPane.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "target_surface_id": targetSurfaceId.uuidString,
                "target_surface_ref": v2Ref(kind: .surface, uuid: targetSurfaceId)
            ])
        }
        return result
    }

    func v2PaneBreak(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to break pane", data: nil)
        v2MainSync {
            guard let sourceWorkspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let sourcePaneUUID = v2UUID(params, "pane_id")
            let sourcePane: PaneID? = {
                if let sourcePaneUUID {
                    return sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == sourcePaneUUID })
                }
                return sourceWorkspace.bonsplitController.focusedPaneId
            }()

            let surfaceId: UUID? = {
                if let explicitSurface = v2UUID(params, "surface_id") { return explicitSurface }
                if let sourcePane,
                   let selected = sourceWorkspace.bonsplitController.selectedTab(inPane: sourcePane) {
                    return sourceWorkspace.panelIdFromSurfaceId(selected.id)
                }
                return sourceWorkspace.focusedPanelId
            }()
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No source surface to break", data: nil)
                return
            }
            guard sourceWorkspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)
            let sourcePaneForRollback = sourceWorkspace.paneId(forPanelId: surfaceId)

            guard let detached = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                result = .err(code: "internal_error", message: "Failed to detach source surface", data: nil)
                return
            }

            guard let destinationWorkspace = tabManager.addWorkspace(
                fromDetachedSurface: detached,
                select: focus
            ) else {
                if let sourcePaneForRollback {
                    _ = sourceWorkspace.attachDetachedSurface(
                        detached,
                        inPane: sourcePaneForRollback,
                        atIndex: sourceIndex,
                        focus: true
                    )
                }
                result = .err(code: "internal_error", message: "Failed to create workspace for detached surface", data: nil)
                return
            }
            guard let destinationPaneId = destinationWorkspace.paneId(forPanelId: surfaceId)?.id else {
                result = .err(
                    code: "internal_error",
                    message: "Failed to resolve destination pane for detached surface",
                    data: [
                        "workspace_id": destinationWorkspace.id.uuidString,
                        "surface_id": surfaceId.uuidString
                    ]
                )
                return
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": destinationWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: destinationWorkspace.id),
                "pane_id": destinationPaneId.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPaneId),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }
        return result
    }

    func v2PaneJoin(params: [String: Any]) -> V2CallResult {
        guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }

        var surfaceId = v2UUID(params, "surface_id")
        if surfaceId == nil, let sourcePaneUUID = v2UUID(params, "pane_id") {
            guard let sourceLocated = v2LocatePane(sourcePaneUUID),
                  let selected = sourceLocated.workspace.bonsplitController.selectedTab(inPane: sourceLocated.paneId),
                  let selectedSurface = sourceLocated.workspace.panelIdFromSurfaceId(selected.id) else {
                return .err(code: "not_found", message: "Unable to resolve selected surface in source pane", data: [
                    "pane_id": sourcePaneUUID.uuidString
                ])
            }
            surfaceId = selectedSurface
        }
        guard let surfaceId else {
            return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
        }

        var moveParams: [String: Any] = [
            "surface_id": surfaceId.uuidString,
            "pane_id": targetPaneUUID.uuidString
        ]
        if let focus = v2Bool(params, "focus") {
            moveParams["focus"] = focus
        }
        return v2SurfaceMove(params: moveParams)
    }

    func v2PaneLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No alternate pane available", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard let focused = ws.bonsplitController.focusedPaneId else {
                result = .err(code: "not_found", message: "No focused pane", data: nil)
                return
            }
            guard let target = ws.bonsplitController.allPaneIds.first(where: { $0.id != focused.id }) else {
                result = .err(code: "not_found", message: "No alternate pane available", data: nil)
                return
            }

            ws.bonsplitController.focusPane(target)
            let selectedSurfaceId = ws.bonsplitController.selectedTab(inPane: target).flatMap { ws.panelIdFromSurfaceId($0.id) }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": target.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: target.id),
                "surface_id": v2OrNull(selectedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceId)
            ])
        }
        return result
    }

    // MARK: - V2 Notification Methods

}
