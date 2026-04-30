import Bonsplit
import Foundation

extension TerminalController {
    func v2ResolveReadableFilePath(_ rawPath: String) -> (path: String?, error: V2CallResult?) {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        guard filePath.hasPrefix("/") else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path must be absolute: \(filePath)",
                    data: ["path": filePath]
                )
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return (
                nil,
                .err(code: "not_found", message: "File not found: \(filePath)", data: ["path": filePath])
            )
        }
        guard !isDir.boolValue else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path is a directory, not a file: \(filePath)",
                    data: ["path": filePath]
                )
            )
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return (
                nil,
                .err(
                    code: "permission_denied",
                    message: "File not readable: \(filePath)",
                    data: ["path": filePath]
                )
            )
        }

        return (filePath, nil)
    }

    private func v2FileOpenSurfacePayload(
        workspace: Workspace,
        panel: FilePreviewPanel
    ) -> [String: Any] {
        let paneUUID = workspace.paneId(forPanelId: panel.id)?.id
        return [
            "surface_id": panel.id.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
            "pane_id": v2OrNull(paneUUID?.uuidString),
            "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
            "path": panel.filePath,
            "preview_mode": panel.previewMode.socketName
        ]
    }

    func v2FileOpen(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let rawPaths = v2StringArray(params, "paths") ?? v2StringArray(params, "path") ?? []
        guard !rawPaths.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'path' or 'paths' parameter", data: nil)
        }

        var filePaths: [String] = []
        for rawPath in rawPaths {
            let resolved = v2ResolveReadableFilePath(rawPath)
            if let error = resolved.error {
                return error
            }
            if let path = resolved.path {
                filePaths.append(path)
            }
        }

        let shouldFocus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to open file preview", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            if shouldFocus {
                v2MaybeFocusWindow(for: tabManager)
                v2MaybeSelectWorkspace(tabManager, workspace: ws)
            }

            let requestedPaneUUID = v2UUID(params, "pane_id")
            let requestedSurfaceUUID = v2UUID(params, "surface_id")
            let hasExplicitPaneDestination = requestedPaneUUID != nil || requestedSurfaceUUID != nil
            let paneId: PaneID?
            if let paneUUID = requestedPaneUUID {
                paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                if paneId == nil {
                    result = .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
                    return
                }
            } else if let surfaceId = requestedSurfaceUUID {
                guard ws.panels[surfaceId] != nil else {
                    result = .err(
                        code: "not_found",
                        message: "Source surface not found",
                        data: ["surface_id": surfaceId.uuidString]
                    )
                    return
                }
                paneId = ws.paneId(forPanelId: surfaceId)
            } else {
                paneId = ws.bonsplitController.focusedPaneId ?? ws.bonsplitController.allPaneIds.first
            }

            guard let paneId else {
                result = .err(code: "not_found", message: "Pane not found", data: nil)
                return
            }

            let openedPanels = ws.openFilePreviewSurfaces(
                inPane: paneId,
                filePaths: filePaths,
                focus: shouldFocus,
                reuseExisting: filePaths.count == 1 && !hasExplicitPaneDestination
            )
            guard !openedPanels.isEmpty else {
                result = .err(code: "internal_error", message: "Failed to create file preview", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            let surfacePayloads = openedPanels.map {
                v2FileOpenSurfacePayload(workspace: ws, panel: $0)
            }
            let primary = surfacePayloads.last ?? [:]
            let paneUUID = ws.paneId(forPanelId: openedPanels.last?.id ?? openedPanels[0].id)?.id
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "surface_id": primary["surface_id"] ?? NSNull(),
                "surface_ref": primary["surface_ref"] ?? NSNull(),
                "path": primary["path"] ?? NSNull(),
                "paths": filePaths,
                "surfaces": surfacePayloads
            ])
        }
        return result
    }
}
