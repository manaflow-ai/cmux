internal import Foundation

/// The parameterized inline VS Code control domain.
extension ControlCommandCoordinator {
    /// A typed view of the inline-VS-Code slice of ``context``.
    var inlineVSCodeContext: (any ControlInlineVSCodeContext)? {
        context as? any ControlInlineVSCodeContext
    }

    /// Dispatches `vscode.open`.
    func handleInlineVSCode(_ request: ControlRequest) -> ControlCallResult? {
        guard request.method == "vscode.open" else { return nil }
        return inlineVSCodeOpen(request.params)
    }

    /// `vscode.open` — open a validated directory in an inline editor pane.
    func inlineVSCodeOpen(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let rawPath = string(params, "path") else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.vscode.error.missingPath",
                    defaultValue: "Missing 'path' parameter",
                    bundle: .main
                ),
                data: nil
            )
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = expanded.hasPrefix("/")
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .err(
                code: "not_found",
                message: String(
                    localized: "socket.vscode.error.directoryNotFound",
                    defaultValue: "Directory not found",
                    bundle: .main
                ),
                data: .object(["path": .string(resolved)])
            )
        }
        guard isDirectory.boolValue else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.vscode.error.notDirectory",
                    defaultValue: "Path is not a directory",
                    bundle: .main
                ),
                data: .object(["path": .string(resolved)])
            )
        }

        let resolution = inlineVSCodeContext?.controlInlineVSCodeOpen(
            routing: routingSelectors(params),
            directoryPath: resolved
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return inlineVSCodeError(
                code: "unavailable",
                key: "socket.vscode.error.tabManagerUnavailable",
                fallback: "TabManager not available"
            )
        case .workspaceNotFound:
            return inlineVSCodeError(
                code: "not_found",
                key: "socket.vscode.error.workspaceNotFound",
                fallback: "Workspace not found"
            )
        case .vscodeUnavailable:
            return inlineVSCodeError(
                code: "unavailable",
                key: "socket.vscode.error.unavailable",
                fallback: "VS Code Inline is unavailable"
            )
        case .openFailed:
            return inlineVSCodeError(
                code: "internal_error",
                key: "socket.vscode.error.openFailed",
                fallback: "Failed to open VS Code Inline"
            )
        case .accepted(let windowID, let workspaceID):
            return .ok(.object([
                "window_id": windowID.map { .string($0.uuidString) } ?? .null,
                "workspace_id": .string(workspaceID.uuidString),
                "path": .string(resolved),
                "accepted": .bool(true),
            ]))
        }
    }

    /// Builds one localized inline VS Code error response.
    private func inlineVSCodeError(
        code: String,
        key: StaticString,
        fallback: String.LocalizationValue
    ) -> ControlCallResult {
        .err(
            code: code,
            message: String(localized: key, defaultValue: fallback, bundle: .main),
            data: nil
        )
    }
}
