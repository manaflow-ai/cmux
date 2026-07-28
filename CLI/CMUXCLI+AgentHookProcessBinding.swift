import Foundation

extension CMUXCLI {
    struct AgentHookProcessBindingResult {
        let binding: CallerTerminalBinding?
        let rejectsAmbientClaim: Bool
    }

    enum AgentHookProcessBindingProbe {
        case notAttempted
        case unsupported
        case failed
        case resolved(CallerTerminalBinding)
    }

    func liveAgentControllingTTYBinding(
        pid: Int?,
        client: SocketClient
    ) -> AgentHookProcessBindingProbe {
        guard !client.isRelayBacked, let pid, pid > 0 else {
            return .notAttempted
        }

        let payload: [String: Any]
        do {
            payload = try client.sendV2(
                method: "agent.resolve_delivery_target",
                params: [
                    "pid": pid,
                    "pid_resolution": AgentProcessBindingResolution.controllingTTY.rawValue,
                ],
                responseTimeout: 2
            )
        } catch let error as CLIError where error.v2Code == "method_not_found"
                || error.v2Code == "unrecognized_method" {
            return .unsupported
        } catch {
            return .failed
        }

        guard (payload["source"] as? String) == "pid",
              (payload["pid_resolution"] as? String) == AgentProcessBindingResolution.controllingTTY.rawValue,
              let workspaceId = normalizedHandleValue(payload["workspace_id"] as? String),
              isUUID(workspaceId),
              let surfaceId = normalizedHandleValue(payload["surface_id"] as? String),
              isUUID(surfaceId) else {
            return .failed
        }
        return .resolved(CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func resolveAgentHookProcessBinding(
        pid: Int?,
        client: SocketClient
    ) -> AgentHookProcessBindingResult {
        switch liveAgentControllingTTYBinding(pid: pid, client: client) {
        case .resolved(let binding):
            return AgentHookProcessBindingResult(binding: binding, rejectsAmbientClaim: false)
        case .unsupported:
            return AgentHookProcessBindingResult(
                binding: uniqueCallerTerminalBindingByTTY(client: client)
                    ?? resolveAgentProcessTerminalBinding(pid: pid, client: client),
                rejectsAmbientClaim: false
            )
        case .failed:
            return AgentHookProcessBindingResult(binding: nil, rejectsAmbientClaim: true)
        case .notAttempted:
            return AgentHookProcessBindingResult(
                binding: uniqueCallerTerminalBindingByTTY(client: client),
                rejectsAmbientClaim: false
            )
        }
    }

    func clearSupersededAgentHookSessions(
        _ records: [ClaudeHookSessionRecord],
        statusKey: String,
        client: SocketClient
    ) {
        for record in records {
            clearAgentSurfaceResumeBinding(
                client: client,
                workspaceId: record.workspaceId,
                surfaceId: record.surfaceId,
                sessionId: record.sessionId
            )
            let pidKey = "\(statusKey).\(record.sessionId)"
            _ = try? sendV1Command(
                "clear_agent_pid \(pidKey) --tab=\(record.workspaceId)\(socketPanelOption(record.surfaceId)) --clear-status",
                client: client
            )
        }
    }
}
