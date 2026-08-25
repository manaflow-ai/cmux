import Foundation

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
        responseTimeout: TimeInterval? = nil
    ) -> AgentSurfaceResumeBindingClearOutcome {
        let normalizedSessionId = normalizedHookValue(sessionId)
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
        do {
            let result = try client.sendV2(
                method: "surface.resume.clear",
                params: params,
                responseTimeout: responseTimeout
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
