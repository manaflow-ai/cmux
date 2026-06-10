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


// MARK: - V2 workspace and tab action dispatch
extension TerminalController {
    func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }
        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "set_description", "clear_description",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread",
            "set_color", "clear_color"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "set_description":
                guard let descriptionRaw = v2String(params, "description"),
                      !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid description", data: nil)
                    return
                }
                tabManager.setCustomDescription(tabId: workspace.id, description: descriptionRaw)
                finish(["description": v2OrNull(workspace.customDescription)])

            case "clear_description":
                tabManager.clearCustomDescription(tabId: workspace.id)
                finish(["description": NSNull()])

            case "move_up":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: max(currentIndex - 1, 0))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: min(currentIndex + 1, tabManager.tabs.count - 1))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
                finish()

            case "set_color":
                guard let colorRaw = v2String(params, "color"),
                      !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid color", data: nil)
                    return
                }
                let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Resolve named colors from the effective palette, including file-defined additions.
                let effectivePalette = WorkspaceTabColorSettings.palette()
                let hex: String
                if let entry = effectivePalette.first(where: {
                    $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
                }) {
                    hex = entry.hex
                } else if let normalized = WorkspaceTabColorSettings.normalizedHex(colorInput) {
                    hex = normalized
                } else {
                    let colorNames = effectivePalette.map(\.name)
                    result = .err(code: "invalid_params", message: "Invalid color. Use a hex value (#RRGGBB) or a named color.", data: [
                        "named_colors": colorNames
                    ])
                    return
                }
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                finish(["color": hex])

            case "clear_color":
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                finish(["color": NSNull()])

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    func v2TabAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "rename", "clear_name",
            "close_left", "close_right", "close_others",
            "new_terminal_right", "new_browser_right",
            "reload", "duplicate", "move_to_new_workspace", "detach_to_workspace", "detach_to_new_workspace",
            "pin", "unpin", "mark_read", "mark_unread"
        ]
        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown tab action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard workspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: [
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ])
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ]
                if let paneId = workspace.paneId(forPanelId: surfaceId)?.id {
                    payload["pane_id"] = paneId.uuidString
                    payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneId)
                } else {
                    payload["pane_id"] = NSNull()
                    payload["pane_ref"] = NSNull()
                }
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            @MainActor
            func insertionIndexToRight(anchorTabId: TabID, inPane paneId: PaneID) -> Int {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
                let pinnedCount = tabs.reduce(into: 0) { count, tab in
                    if let panelId = workspace.panelIdFromSurfaceId(tab.id),
                       workspace.isPanelPinned(panelId) {
                        count += 1
                    }
                }
                let rawTarget = min(anchorIndex + 1, tabs.count)
                return max(rawTarget, pinnedCount)
            }

            @MainActor
            func closeTabs(_ tabIds: [TabID]) -> (closed: Int, skippedPinned: Int) {
                var closed = 0
                var skippedPinned = 0
                for tabId in tabIds {
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId) else { continue }
                    if workspace.isPanelPinned(panelId) {
                        skippedPinned += 1
                        continue
                    }
                    if workspace.panels.count <= 1 {
                        break
                    }
                    if workspace.requestCloseTabRecordingHistory(tabId, force: true) {
                        closed += 1
                    }
                }
                return (closed, skippedPinned)
            }

            switch action {
            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = .err(code: "invalid_params", message: "Missing or invalid title", data: nil)
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                workspace.setPanelCustomTitle(panelId: surfaceId, title: title)
                finish(["title": title])

            case "clear_name":
                workspace.setPanelCustomTitle(panelId: surfaceId, title: nil)
                finish()

            case "pin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: true)
                finish(["pinned": true])

            case "unpin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: false)
                finish(["pinned": false])

            case "mark_read":
                workspace.markPanelRead(surfaceId)
                finish()

            case "mark_unread", "mark_as_unread":
                workspace.markPanelUnread(surfaceId)
                finish()

            case "move_to_new_workspace", "detach_to_workspace", "detach_to_new_workspace":
                result = v2MoveTabToNewWorkspaceActionResult(action: action, params: params, tabManager: tabManager, workspace: workspace, surfaceId: surfaceId)
            case "reload", "reload_tab":
                guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Reload is only available for browser tabs", data: nil)
                    return
                }
                browserPanel.reload()
                finish()

            case "duplicate", "duplicate_tab":
                guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Duplicate is only available for browser tabs", data: nil)
                    return
                }
                guard BrowserAvailabilitySettings.isEnabled() else {
                    result = v2BrowserDisabledExternalOpenResult(
                        url: browserPanel.currentURLForTabDuplication,
                        tabManager: tabManager
                    )
                    return
                }

                guard let newPanel = workspace.duplicateBrowserToRight(panelId: surfaceId, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to duplicate tab", data: nil)
                    return
                }
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_terminal_right", "new_terminal_to_right", "new_terminal_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newTerminalSurface(inPane: paneId, focus: focus) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_browser_right", "new_browser_to_right", "new_browser_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let urlRaw = v2String(params, "url")
                let url = urlRaw.flatMap { URL(string: $0) }
                if urlRaw != nil && url == nil {
                    result = .err(code: "invalid_params", message: "Invalid URL", data: ["url": v2OrNull(urlRaw)])
                    return
                }
                guard BrowserAvailabilitySettings.isEnabled() else {
                    result = v2BrowserDisabledExternalOpenResult(
                        rawURL: urlRaw,
                        url: url,
                        tabManager: tabManager
                    )
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(
                    inPane: paneId,
                    url: url,
                    focus: focus,
                    creationPolicy: .automationPreload
                ) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "close_left", "close_to_left":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = Array(tabs.prefix(index).map(\.id))
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_right", "close_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = (index + 1 < tabs.count) ? Array(tabs.suffix(from: index + 1).map(\.id)) : []
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_others", "close_other_tabs":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let targetIds = workspace.bonsplitController.tabs(inPane: paneId)
                    .map(\.id)
                    .filter { $0 != anchorTabId }
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            default:
                result = .err(code: "invalid_params", message: "Unknown tab action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    // MARK: - V2 Surface Methods

}
