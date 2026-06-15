internal import Foundation

#if DEBUG
extension ControlCommandCoordinator {
    // MARK: - debug.gui_mode.open

    func debugGuiModeOpen() -> ControlCallResult {
        guard let workspaceID = debugContext?.controlDebugOpenGuiModeWorkspace() else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
        ]))
    }

    // MARK: - debug.gui_mode.submit

    func debugGuiModeSubmit(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let prompt = string(params, "prompt") else {
            return .err(code: "invalid_params", message: "Missing prompt", data: nil)
        }
        let providerID = string(params, "provider_id") ?? string(params, "provider")
        let resolution = debugContext?.controlDebugSubmitGuiModeTask(
            prompt: prompt,
            providerID: providerID
        ) ?? .unavailable
        switch resolution {
        case .created(let workspaceID):
            return .ok(.object([
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
            ]))
        case .invalidProvider(let rawProviderID):
            return .err(
                code: "invalid_params",
                message: "Unknown provider: \(rawProviderID)",
                data: nil
            )
        case .sourceNotFound:
            return .err(code: "not_found", message: "GUI mode workspace not found", data: nil)
        case .unavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
    }
}
#endif
