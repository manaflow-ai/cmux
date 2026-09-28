import CmuxAgentChat
import CmuxSurfaceCatalogModel
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
            guard let agents = await Self.captureAgentActivity() else {
                throw SurfaceCatalogError.unsupported("Agent session owners are unavailable")
            }
            return ["agents": agents.map(Self.agentListPayload)]
        }
    }

    @MainActor
    /// Nil when the app or its session registry is not up: an empty list would
    /// wrongly say no agent is running.
    private static func captureAgentActivity() async -> [AgentActivitySnapshot]? {
        guard let appDelegate = AppDelegate.shared,
              let sessions = TerminalController.shared.agentChatTranscriptService else { return nil }
        return await AgentActivityIndex(
            agentRecords: { sessions.sessionRecords(workspaceID: nil) },
            workspaceOwners: { [weak appDelegate] in appDelegate?.workspacesForRead(tabIds: $0) ?? [:] }
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
                // Unredacted: agent.list is a same-user local socket kept off the
                // remote relay, and the same user can read this argv with ps.
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
