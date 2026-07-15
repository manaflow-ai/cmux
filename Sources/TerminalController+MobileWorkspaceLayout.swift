import Foundation

extension TerminalController {
    /// Returns the authoritative pane-and-tab topology for one explicit workspace.
    func v2MobileWorkspaceLayout(params: [String: Any]) -> V2CallResult {
        guard v2HasNonNullParam(params, "workspace_id"),
              let workspaceID = v2UUID(params, "workspace_id") else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid workspace_id",
                data: nil
            )
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: ["workspace_id": workspaceID.uuidString]
            )
        }
        do {
            let data = try JSONEncoder().encode(workspace.mobileWorkspaceLayout())
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .err(
                    code: "internal_error",
                    message: "Failed to encode workspace layout",
                    data: nil
                )
            }
            return .ok(payload)
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to encode workspace layout",
                data: nil
            )
        }
    }
}
