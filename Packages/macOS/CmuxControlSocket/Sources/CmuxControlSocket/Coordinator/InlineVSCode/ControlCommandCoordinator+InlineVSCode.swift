internal import Foundation

/// The parameterized inline VS Code control domain.
extension ControlCommandCoordinator {
    /// `vscode.open` validates a directory off-main, then queues the UI work in
    /// one bounded ``ControlCommandContext/controlResolveOnMain(_:)`` hop.
    ///
    /// Serve-web startup is asynchronous and its completion is delivered on
    /// the main actor. The synchronous control wire therefore returns an
    /// explicit `queued` status after the request is accepted; it does not
    /// claim the browser pane has finished opening.
    func inlineVSCodeOpen(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?,
        deadline: Date?
    ) async -> ControlCallResult? {
        guard let context else { return nil }
        let strings = context.controlInlineVSCodeStrings()
        guard case .string(let rawPath)? = params["path"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: strings.missingPath, data: nil)
        }

        // Keep the caller's path bytes intact. Leading and trailing whitespace
        // can be part of a valid file name; trimming is only used for the
        // empty-input check above.
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved: String
        if NSString(string: expanded).isAbsolutePath {
            resolved = expanded
        } else {
            let callerDirectory: String
            switch params["cwd"] {
            case nil, .some(.null):
                callerDirectory = inlineVSCodeFileSystem.currentDirectoryPath()
            case .some(.string(let value)):
                guard NSString(string: value).isAbsolutePath else {
                    return .err(
                        code: "invalid_params",
                        message: strings.cwdMustBeAbsolute,
                        data: nil
                    )
                }
                callerDirectory = value
            default:
                return .err(
                    code: "invalid_params",
                    message: strings.cwdMustBeAbsolute,
                    data: nil
                )
            }
            resolved = NSString(string: callerDirectory).appendingPathComponent(expanded)
        }
        guard !hasInvalidSurfaceAliases(params) else {
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        }
        let routing = routingSelectors(params)
        // Every explicit selector must resolve. Otherwise the app cannot
        // distinguish a bad target from an intentionally omitted one and
        // could fall through to the selected workspace.
        if (routing.hasWindowIDParam && routing.windowID == nil)
            || (routing.hasGroupIDParam && routing.groupID == nil)
            || (routing.hasWorkspaceIDParam && routing.workspaceID == nil)
            || (routing.hasSurfaceIDParam && routing.surfaceID == nil)
            || (routing.hasPaneIDParam && routing.paneID == nil) {
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        }
        let openResult = await context.controlInlineVSCodeOpen(
            routing: routing,
            directoryPath: resolved,
            deadline: deadline
        )
        switch openResult.resolution {
        case .directoryNotFound:
            return .err(
                code: "not_found",
                message: strings.directoryNotFound,
                data: .object(["path": .string(openResult.path)])
            )
        case .notDirectory:
            return .err(
                code: "invalid_params",
                message: strings.notDirectory,
                data: .object(["path": .string(openResult.path)])
            )
        case .validationUnavailable:
            return .err(code: "unavailable", message: strings.openFailed, data: nil)
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: strings.tabManagerUnavailable, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        case .vscodeUnavailable:
            return .err(code: "unavailable", message: strings.vscodeUnavailable, data: nil)
        case .openFailed:
            return .err(code: "internal_error", message: strings.openFailed, data: nil)
        case .accepted(let windowID, let workspaceID):
            let windowRef = windowID.map { ref(.window, $0) }
            let workspaceRef = ref(.workspace, workspaceID)
            let windowValue = windowID.map { JSONValue.string($0.uuidString) } ?? .null
            let payload: [String: JSONValue] = [
                "window_id": windowValue,
                "window_ref": windowRef ?? .null,
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": workspaceRef,
                "path": .string(openResult.path),
                "accepted": .bool(true),
                "status": .string("queued"),
            ]
            return .ok(.object(payload))
        }
    }

}
