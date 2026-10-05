import Foundation

@MainActor
extension TerminalController {
    /// Exports verified native identities and journal observations without transcripts or environment values.
    func v2AgentRuntimeList(params: [String: Any]) -> V2CallResult {
        let managers = AppDelegate.shared?.agentDeliveryTabManagers() ?? [tabManager].compactMap { $0 }
        var workspaces = managers.flatMap(\.tabs)
        if params.keys.contains("workspace_id") {
            guard let id = v2UUID(params, "workspace_id") else { return .err(code: "invalid_params", message: invalidParameters, data: nil) }
            workspaces.removeAll { $0.id != id }
        }
        if params.keys.contains("surface_id") {
            guard let id = v2UUID(params, "surface_id") else { return .err(code: "invalid_params", message: invalidParameters, data: nil) }
            workspaces.removeAll { $0.panels[id] == nil }
        }
        if params.keys.contains("limit"), v2StrictInt(params, "limit") == nil { return .err(code: "invalid_params", message: invalidParameters, data: nil) }
        let limit = v2StrictInt(params, "limit") ?? 1_024
        guard limit >= 1 && limit <= 1_024 else { return .err(code: "invalid_params", message: invalidParameters, data: nil) }
        let result = AgentRuntimeObservationReader().read(workspaces: workspaces, surfaceID: v2UUID(params, "surface_id"), limit: limit)
        return .ok(result)
    }

    private var invalidParameters: String {
        String(localized: "agent.runtime.error.invalidParameters", defaultValue: "Use valid workspace and surface IDs and a limit between 1 and 1024.")
    }
}
