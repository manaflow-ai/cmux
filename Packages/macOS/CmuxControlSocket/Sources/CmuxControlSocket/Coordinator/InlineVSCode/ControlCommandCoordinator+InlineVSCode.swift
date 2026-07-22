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
    nonisolated func inlineVSCodeOpen(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let strings = context?.controlInlineVSCodeStrings() ?? Self.fallbackInlineVSCodeStrings
        guard case .string(let rawPath)? = params["path"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: strings.missingPath, data: nil)
        }

        // Keep the caller's path bytes intact. Leading and trailing whitespace
        // can be part of a valid file name; trimming is only used for the
        // empty-input check above.
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = expanded.hasPrefix("/")
            ? expanded
            : (inlineVSCodeFileSystem.currentDirectoryPath() as NSString).appendingPathComponent(expanded)
        let inspection = inlineVSCodeFileSystem.inspectPath(resolved)
        guard inspection.exists else {
            return .err(
                code: "not_found",
                message: strings.directoryNotFound,
                data: .object(["path": .string(resolved)])
            )
        }
        guard inspection.isDirectory else {
            return .err(
                code: "invalid_params",
                message: strings.notDirectory,
                data: .object(["path": .string(resolved)])
            )
        }
        guard let context else {
            return .err(code: "unavailable", message: strings.tabManagerUnavailable, data: nil)
        }

        let resolution: ControlInlineVSCodeOpenResolution = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            // Every explicit selector must resolve. Otherwise the app cannot
            // distinguish a bad target from an intentionally omitted one and
            // could fall through to the selected workspace.
            if (routing.hasGroupIDParam && routing.groupID == nil)
                || (routing.hasWorkspaceIDParam && routing.workspaceID == nil)
                || (routing.hasSurfaceIDParam && routing.surfaceID == nil)
                || (routing.hasPaneIDParam && routing.paneID == nil) {
                return .workspaceNotFound
            }
            return seam.controlInlineVSCodeOpen(routing: routing, directoryPath: resolved)
        }
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: strings.tabManagerUnavailable, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: strings.workspaceNotFound, data: nil)
        case .vscodeUnavailable:
            return .err(code: "unavailable", message: strings.vscodeUnavailable, data: nil)
        case .openFailed:
            return .err(code: "internal_error", message: strings.openFailed, data: nil)
        case .accepted(let windowID, let workspaceID):
            let windowValue = windowID.map { JSONValue.string($0.uuidString) } ?? .null
            let payload: [String: JSONValue] = [
                "window_id": windowValue,
                "workspace_id": .string(workspaceID.uuidString),
                "path": .string(resolved),
                "accepted": .bool(true),
                "status": .string("queued"),
            ]
            return .ok(.object(payload))
        }
    }

    /// Stable English fallbacks for nil/partial test contexts. Production
    /// always obtains app-bundle-resolved strings through the context seam.
    private nonisolated static let fallbackInlineVSCodeStrings = ControlInlineVSCodeStrings(
        missingPath: "Missing 'path' parameter",
        directoryNotFound: "Directory not found",
        notDirectory: "Path is not a directory",
        tabManagerUnavailable: "The inline editor is unavailable",
        workspaceNotFound: "Workspace not found",
        vscodeUnavailable: "VS Code Inline is unavailable",
        openFailed: "Failed to open VS Code Inline"
    )
}
