import Foundation
import CmuxControlSocket

extension CMUXCLI {
    /// The ownership result returned by a guarded agent resume-binding clear.
    enum AgentSurfaceResumeBindingClearOutcome: Equatable {
        case cleared
        case checkpointDidNotOwnBinding
        case failed
    }

    func clearAgentSurfaceResumeBindingOutcome(
        client: SocketClient,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?,
        sessionDidEnd: Bool = false,
        expectedBindingUpdatedAt: TimeInterval? = nil,
        agentMutationGuard: ControlSidebarAgentMutationGuard? = nil,
        responseTimeout: TimeInterval? = nil,
        deadline: Date? = nil
    ) -> AgentSurfaceResumeBindingClearOutcome {
        let normalizedSessionId = normalizedHookValue(sessionId)
            .map(agentHookResumeSessionID)
        var params: [String: Any] = [
            "surface_id": surfaceId,
            "source": "agent-hook"
        ]
        if let normalizedSessionId {
            params["checkpoint_id"] = normalizedSessionId
        }
        if sessionDidEnd, normalizedSessionId != nil {
            params["agent_session_ended"] = true
        }
        if let expectedBindingUpdatedAt, expectedBindingUpdatedAt.isFinite {
            params["_cmux_expected_updated_at"] = expectedBindingUpdatedAt
        }
        if let agentMutationGuard {
            params["_cmux_agent_mutation_guard"] = agentMutationGuard.socketEnvelope
        }
        do {
            let result = try client.sendV2(
                method: "surface.resume.clear",
                params: params,
                responseTimeout: responseTimeout,
                deadline: deadline
            )
            guard let cleared = result["cleared"] as? Bool else {
                return .failed
            }
            return cleared ? .cleared : .checkpointDidNotOwnBinding
        } catch {
            return .failed
        }
    }
}
