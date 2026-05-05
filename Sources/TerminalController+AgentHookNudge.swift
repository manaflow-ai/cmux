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

    func agentHooksNudge(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard let agentName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentName.isEmpty else {
            return "ERROR: Usage: agent_hooks_nudge <agent> --tab=<uuid> [--panel=<uuid>|--surface=<uuid>]"
        }

        var tabId: UUID?
        var surfaceId: UUID?
        for part in parts.dropFirst() {
            if part.hasPrefix("--tab=") {
                tabId = UUID(uuidString: String(part.dropFirst("--tab=".count)))
            } else if part.hasPrefix("--panel=") {
                surfaceId = UUID(uuidString: String(part.dropFirst("--panel=".count)))
            } else if part.hasPrefix("--surface=") {
                surfaceId = UUID(uuidString: String(part.dropFirst("--surface=".count)))
            }
        }
        guard let tabId else {
            return "ERROR: agent_hooks_nudge requires --tab=<uuid>"
        }

        TerminalMutationBus.shared.enqueueMainActorMutation {
            AgentHookIntegrationSettings.showSetupPromptIfNeeded(
                agentName: agentName,
                tabId: tabId,
                surfaceId: surfaceId
            )
        }
        return "OK"
    }

}
