internal import Foundation

/// The file-into-panel openers of the project domain: `markdown.open` and
/// `file.open`, lifted byte-faithfully from the former
/// `TerminalController.v2MarkdownOpen` / `v2FileOpen` bodies (including the
/// pure-Foundation readable-path validation, which both share).
extension ControlCommandCoordinator {
    /// `markdown.open` — open a markdown split next to a source surface.
    func markdownOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard projectContext?.controlProjectRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawPath = string(params, "path") else {
            return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
        }

        let resolvedFilePath = resolveReadableFilePath(rawPath)
        if let error = resolvedFilePath.error {
            return error
        }
        guard let filePath = resolvedFilePath.path else {
            return .err(code: "internal_error", message: "Failed to resolve file path", data: nil)
        }

        let directionRaw = string(params, "direction") ?? "right"
        let fontSizeInvalid = params["font_size"] != nil && double(params, "font_size") == nil
        let resolution = projectContext?.controlMarkdownOpen(
            routing: routing,
            surfaceID: uuid(params, "surface_id"),
            filePath: filePath,
            directionRaw: directionRaw,
            fontSize: double(params, "font_size"),
            fontSizeInvalid: fontSizeInvalid,
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .createFailed
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedSurface:
            return .err(code: "not_found", message: "No focused surface to split", data: nil)
        case .sourceSurfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Source surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .invalidDirection:
            return .err(
                code: "invalid_params",
                message: "Invalid direction '\(directionRaw)' (left|right|up|down)",
                data: nil
            )
        case .invalidFontSize:
            return .err(code: "invalid_params", message: "Invalid 'font_size' (expected a number)", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create markdown panel", data: nil)
        case .opened(let created):
            return .ok(.object([
                "window_id": orNull(created.windowID?.uuidString),
                "window_ref": ref(.window, created.windowID),
                "workspace_id": .string(created.workspaceID.uuidString),
                "workspace_ref": ref(.workspace, created.workspaceID),
                "pane_id": orNull(created.targetPaneID?.uuidString),
                "pane_ref": ref(.pane, created.targetPaneID),
                "surface_id": .string(created.surfaceID.uuidString),
                "surface_ref": ref(.surface, created.surfaceID),
                "source_surface_id": .string(created.sourceSurfaceID.uuidString),
                "source_surface_ref": ref(.surface, created.sourceSurfaceID),
                "source_pane_id": orNull(created.sourcePaneID?.uuidString),
                "source_pane_ref": ref(.pane, created.sourcePaneID),
                "target_pane_id": orNull(created.targetPaneID?.uuidString),
                "target_pane_ref": ref(.pane, created.targetPaneID),
                "path": .string(filePath),
            ]))
        }
    }

    /// `file.open` — open one or more files as preview/markdown surfaces.
    func fileOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard projectContext?.controlProjectRoutingResolvesTabManager(routing: routing) == true else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let rawPaths = stringArray(params, "paths") ?? stringArray(params, "path") ?? []
        guard !rawPaths.isEmpty else {
            return .err(code: "invalid_params", message: "Missing 'path' or 'paths' parameter", data: nil)
        }

        var filePaths: [String] = []
        for rawPath in rawPaths {
            let resolved = resolveReadableFilePath(rawPath)
            if let error = resolved.error {
                return error
            }
            if let path = resolved.path {
                filePaths.append(path)
            }
        }

        let resolution = projectContext?.controlFileOpen(
            routing: routing,
            filePaths: filePaths,
            paneID: uuid(params, "pane_id"),
            surfaceID: uuid(params, "surface_id"),
            requestedFocus: bool(params, "focus") ?? true
        ) ?? .openFailed
        switch resolution {
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .requestedPaneNotFound(let paneID):
            return .err(
                code: "not_found",
                message: "Pane not found",
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .sourceSurfaceNotFound(let surfaceID):
            return .err(
                code: "not_found",
                message: "Source surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .paneUnresolved:
            return .err(code: "not_found", message: "Pane not found", data: nil)
        case .openFailed:
            return .err(code: "internal_error", message: "Failed to open file", data: nil)
        case .opened(let windowID, let workspaceID, let surfaces):
            let surfacePayloads = surfaces.map(fileOpenSurfacePayload)
            let primary = surfaces.last
            let paneID = primary?.paneID
            var response: [String: JSONValue] = [
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(paneID?.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": primary.map { JSONValue.string($0.surfaceID.uuidString) } ?? .null,
                "surface_ref": primary != nil ? ref(.surface, primary?.surfaceID) : .null,
                "panel_type": orNull(primary?.panelTypeRawValue),
                "path": orNull(primary?.path),
                "paths": .array(filePaths.map { .string($0) }),
                "surfaces": .array(surfacePayloads),
            ]
            if let previewMode = primary?.previewMode {
                response["preview_mode"] = .string(previewMode)
            }
            if let displayMode = primary?.displayMode {
                response["display_mode"] = .string(displayMode)
            }
            return .ok(.object(response))
        }
    }

    /// One opened-surface row of the `file.open` payload (the legacy
    /// `v2FileOpenSurfacePayload`).
    private func fileOpenSurfacePayload(_ surface: ControlFileOpenSurface) -> JSONValue {
        var payload: [String: JSONValue] = [
            "surface_id": .string(surface.surfaceID.uuidString),
            "surface_ref": ref(.surface, surface.surfaceID),
            "pane_id": orNull(surface.paneID?.uuidString),
            "pane_ref": ref(.pane, surface.paneID),
            "panel_type": .string(surface.panelTypeRawValue),
        ]
        if let path = surface.path {
            payload["path"] = .string(path)
        }
        if let previewMode = surface.previewMode {
            payload["preview_mode"] = .string(previewMode)
        }
        if let displayMode = surface.displayMode {
            payload["display_mode"] = .string(displayMode)
        }
        return .object(payload)
    }

    /// The shared readable-file-path validation of `markdown.open` /
    /// `file.open` (the legacy `v2ResolveReadableFilePath`): tilde-expand,
    /// standardize, then require an absolute, existing, non-directory,
    /// readable file.
    func resolveReadableFilePath(_ rawPath: String) -> (path: String?, error: ControlCallResult?) {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let filePath = NSString(string: expandedPath).standardizingPath

        guard filePath.hasPrefix("/") else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path must be absolute: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "File not found: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }
        guard !isDir.boolValue else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Path is a directory, not a file: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }
        guard FileManager.default.isReadableFile(atPath: filePath) else {
            return (
                nil,
                .err(
                    code: "permission_denied",
                    message: "File not readable: \(filePath)",
                    data: .object(["path": .string(filePath)])
                )
            )
        }

        return (filePath, nil)
    }
}
