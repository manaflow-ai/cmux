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


// MARK: - V2 markdown and project panel methods
extension TerminalController {
    func v2MarkdownOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        let resolvedFilePath = v2ResolveReadableFilePath(rawPath)
        if let error = resolvedFilePath.error {
            return error
        }
        guard let filePath = resolvedFilePath.path else {
            return .err(code: "internal_error", message: "Failed to resolve file path", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId else {
                result = .err(code: "not_found", message: "No focused surface to split", data: nil)
                return
            }
            guard ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "Source surface not found", data: ["surface_id": sourceSurfaceId.uuidString])
                return
            }

            let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

            let directionStr = v2String(params, "direction") ?? "right"
            guard let direction = parseSplitDirection(directionStr) else {
                result = .err(code: "invalid_params", message: "Invalid direction '\(directionStr)' (left|right|up|down)", data: nil)
                return
            }
            let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
            let insertFirst = (direction == .left || direction == .up)

            if params["font_size"] != nil, v2Double(params, "font_size") == nil {
                result = .err(code: "invalid_params", message: "Invalid 'font_size' (expected a number)", data: nil)
                return
            }
            let fontSize = v2Double(params, "font_size").map { MarkdownFontSizeSettings.clamp($0) }

            let createdPanel = ws.newMarkdownSplit(
                from: sourceSurfaceId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath,
                focus: v2FocusAllowed(requested: v2Bool(params, "focus") ?? false),
                fontSize: fontSize
            )

            guard let markdownPanelId = createdPanel?.id else {
                result = .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "surface_id": markdownPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: markdownPanelId),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "source_pane_id": v2OrNull(sourcePaneUUID?.uuidString),
                "source_pane_ref": v2Ref(kind: .pane, uuid: sourcePaneUUID),
                "target_pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "path": filePath
            ])
        }
        return result
    }

    // MARK: - Project

    func v2ProjectOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = v2String(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            resolved = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            return .err(code: "not_found", message: "Project not found at \(resolved)", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create project panel", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            guard let paneId = ws.bonsplitController.focusedPaneId else {
                result = .err(code: "not_found", message: "No focused pane to open project in", data: nil)
                return
            }

            guard let panel = ws.newProjectSurface(
                inPane: paneId,
                projectPath: resolved,
                focus: v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
            ) else {
                result = .err(code: "internal_error", message: "Failed to create project panel", data: nil)
                return
            }
            let targetPaneUUID = ws.paneId(forPanelId: panel.id)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "workspace_id": ws.id.uuidString,
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "surface_id": panel.id.uuidString,
                "path": resolved
            ])
        }
        return result
    }

    // MARK: - Project state driving (debug RPC for autonomous iteration)

    private func v2ResolveProjectPanel(params: [String: Any]) -> (Workspace, ProjectPanel)? {
        guard let tabManager = v2ResolveTabManager(params: params) else { return nil }
        var result: (Workspace, ProjectPanel)?
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let surfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId,
                  let panel = ws.panels[surfaceId] as? ProjectPanel else { return }
            result = (ws, panel)
        }
        return result
    }

    func v2ProjectSetTab(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        guard let raw = v2String(params, "tab"),
              let tab = ProjectPanelTab(rawValue: raw) else {
            return .err(code: "invalid_params", message: "tab must be one of files|targets|buildSettings|schemes", data: nil)
        }
        v2MainSync { panel.activeTab = tab }
        return .ok(["tab": tab.rawValue])
    }

    func v2ProjectSetScheme(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        let name = v2String(params, "name")
        v2MainSync { panel.selectedSchemeName = name }
        return .ok(["scheme": name ?? ""])
    }

    func v2ProjectSetConfiguration(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        let name = v2String(params, "name")
        v2MainSync { panel.selectedConfigurationName = name }
        return .ok(["configuration": name ?? ""])
    }

    func v2ProjectSetSelectedTarget(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        let name = v2String(params, "name")
        var resolvedID: String?
        v2MainSync {
            if let name, !name.isEmpty,
               let module = panel.loadState.model?.modules.first,
               let target = module.targets.first(where: { $0.displayName == name }) {
                panel.selectedTargetID = target.id
                resolvedID = target.id.rawValue
            } else {
                panel.selectedTargetID = nil
            }
        }
        return .ok(["target_name": name ?? "", "target_id": resolvedID ?? ""])
    }

    func v2ProjectSetSelectedFile(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        let path = v2String(params, "path")
        v2MainSync { panel.selectedFilePath = path }
        return .ok(["selected_file": path ?? ""])
    }

    func v2ProjectSetSettingsFilter(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        let text = v2String(params, "text") ?? ""
        v2MainSync { panel.settingsSearchText = text }
        return .ok(["filter": text])
    }

    func v2ProjectGetState(params: [String: Any]) -> V2CallResult {
        guard let (_, panel) = v2ResolveProjectPanel(params: params) else {
            return .err(code: "not_found", message: "Project surface not found", data: nil)
        }
        var snapshot: [String: Any] = [:]
        v2MainSync {
            snapshot["surface_id"] = panel.id.uuidString
            snapshot["project_url"] = panel.projectURL.path
            snapshot["active_tab"] = panel.activeTab.rawValue
            snapshot["selected_scheme"] = panel.selectedSchemeName ?? ""
            snapshot["selected_configuration"] = panel.selectedConfigurationName ?? ""
            snapshot["selected_target_id"] = panel.selectedTargetID?.rawValue ?? ""
            snapshot["selected_file"] = panel.selectedFilePath ?? ""
            snapshot["settings_filter"] = panel.settingsSearchText
            switch panel.loadState {
            case .idle:
                snapshot["load_state"] = "idle"
            case .loading:
                snapshot["load_state"] = "loading"
            case let .failed(reason):
                snapshot["load_state"] = "failed"
                snapshot["load_error"] = reason
            case let .loaded(model):
                snapshot["load_state"] = "loaded"
                snapshot["module_count"] = model.modules.count
                if let module = model.modules.first {
                    snapshot["module_name"] = module.displayName
                    snapshot["target_count"] = module.targets.count
                    snapshot["target_names"] = module.targets.map(\.displayName)
                    snapshot["scheme_count"] = module.schemes.count
                    snapshot["scheme_names"] = module.schemes.map(\.name)
                    snapshot["configuration_names"] = module.configurationNames
                    snapshot["root_group_children"] = module.rootGroup.children.count
                }
            }
        }
        return .ok(snapshot)
    }

    // MARK: - Browser

}
