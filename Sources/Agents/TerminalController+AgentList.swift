import CmuxAgentChat
import Foundation

extension TerminalController {
    /// `agent.list`: every live agent pane with its activity and resume safety.
    ///
    /// A worker-lane read. One main-actor turn joins the session registry to live
    /// panels; the process census and encoding run off the main actor. Local-only:
    /// the payload carries local process argv, so the remote relay never forwards it.
    nonisolated func socketWorkerAgentListResponse(id: Any?, params: [String: Any]) -> String {
        guard params.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "agent.list takes no parameters")
        }
        return v2VmCall(id: id, timeoutSeconds: 10) {
            let agents = await Self.captureAgentActivity()
            return ["agents": agents.map(Self.agentListPayload)]
        }
    }

    @MainActor
    private static func captureAgentActivity() async -> [AgentActivitySnapshot] {
        await AgentActivityIndex(
            agentRecords: { TerminalController.shared.agentChatTranscriptService?.sessionRecords(workspaceID: nil) },
            workspaceOwners: { AppDelegate.shared?.workspacesForRead(tabIds: $0) ?? [:] }
        ).snapshot()
    }

    nonisolated static func agentListPayload(_ agent: AgentActivitySnapshot) -> [String: Any] {
        func orNull(_ value: Any?) -> Any { value ?? NSNull() }
        func timestamp(_ date: Date?) -> Any { orNull(date?.ISO8601Format()) }
        var activity: [String: Any] = [
            "kind": agent.activity.kind.rawValue,
            "since": timestamp(agent.activity.since),
            "source": agent.activity.source.rawValue,
        ]
        if let tool = agent.activity.tool {
            activity["tool"] = [
                "name": tool.name,
                "command": orNull(tool.command),
                "started_at": timestamp(tool.startedAt),
            ] as [String: Any]
        }
        return [
            "workspace_id": agent.workspaceID.uuidString,
            "panel_id": agent.panelID.uuidString,
            "surface_id": agent.surfaceID.uuidString,
            "pane_id": orNull(agent.paneID?.uuidString),
            "name": orNull(agent.name),
            "agent": agent.agentKind,
            "session_id": agent.sessionID,
            "pid": orNull(agent.pid),
            "placement": [
                "kind": agent.placement.kind,
                "host": orNull(agent.placement.host),
            ] as [String: Any],
            "survives_app_relaunch": agent.survivesAppRelaunch,
            "activity": activity,
            "resume_safety": [
                "safety": agent.assessment.safety.rawValue,
                "reasons": agent.assessment.reasons.map(\.rawValue),
            ] as [String: Any],
        ]
    }
}
