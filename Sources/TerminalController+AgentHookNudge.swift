import Foundation

extension TerminalController {
    func v2AgentHooksNudge(params: [String: Any]) -> V2CallResult {
        guard let agentName = v2String(params, "agent") else {
            return .err(code: "invalid_params", message: "Missing agent", data: ["field": "agent"])
        }
        guard let tabId = v2UUID(params, "workspace_id") ?? v2UUID(params, "tab_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id or tab_id", data: ["field": "workspace_id"])
        }
        let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "panel_id")

        TerminalMutationBus.shared.enqueueMainActorMutation {
            AgentHookIntegrationSettings.showSetupPromptIfNeeded(
                agentName: agentName,
                tabId: tabId,
                surfaceId: surfaceId
            )
        }
        return .ok(["queued": true])
    }

}
