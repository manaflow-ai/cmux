import Foundation

extension CMUXCLI {
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
        resolution: AgentProcessBindingResolution,
        client: SocketClient
    ) -> AgentHookProcessBindingResult {
        guard resolution == .controllingTTY else {
            return corroboratedAgentHookProcessBinding(pid: pid, client: client)
        }

        switch liveAgentControllingTTYBinding(pid: pid, client: client) {
        case .resolved(let binding):
            return AgentHookProcessBindingResult(binding: binding, source: .liveProcess, rejectsAmbientClaim: false)
        case .unsupported:
            return corroboratedAgentHookProcessBinding(pid: pid, client: client)
        case .failed:
            return AgentHookProcessBindingResult(binding: nil, source: nil, rejectsAmbientClaim: true)
        case .notAttempted:
            return AgentHookProcessBindingResult(
                binding: uniqueCallerTerminalBindingByTTY(client: client),
                source: .ambientTTY,
                rejectsAmbientClaim: false
            )
        }
    }

    private func corroboratedAgentHookProcessBinding(
        pid: Int?,
        client: SocketClient
    ) -> AgentHookProcessBindingResult {
        if let binding = uniqueCallerTerminalBindingByTTY(client: client) {
            return AgentHookProcessBindingResult(binding: binding, source: .ambientTTY, rejectsAmbientClaim: false)
        }
        return AgentHookProcessBindingResult(
            binding: resolveAgentProcessTerminalBinding(pid: pid, client: client),
            source: .liveProcess,
            rejectsAmbientClaim: false
        )
    }

    func clearSupersededAgentHookSessions(
        _ initialRecords: [ClaudeHookSessionRecord],
        owner: ClaudeHookSessionRecord,
        statusKey: String,
        store: ClaudeHookSessionStore,
        client: SocketClient
    ) {
        var records = initialRecords
        if records.isEmpty {
            records = (try? store.pendingSupersededSessionCleanupCandidates(for: owner)) ?? []
        }
        var clearedRecords: [ClaudeHookSessionRecord] = []
        for record in records {
            let resumeClearOutcome = clearAgentSurfaceResumeBindingOutcome(
                client: client,
                workspaceId: record.workspaceId,
                surfaceId: record.surfaceId,
                sessionId: record.sessionId,
                runtimeStatusKey: statusKey,
                runtimeGeneration: record.runtimeGeneration
            )
            guard resumeClearOutcome != .failed else {
                continue
            }
            if record.surfaceId == owner.surfaceId {
                // Registering the replacement structured PID on this panel has
                // already evicted the superseded key. Avoid a redundant
                // key-miss clear while the replacement may not have published
                // its own PID yet.
                clearedRecords.append(record)
                continue
            }
            let pidKeys = agentRuntimePIDKeys(
                statusKey: statusKey,
                sessionID: record.sessionId
            )
            do {
                for pidKey in pidKeys {
                    _ = try sendV1Command(
                        "clear_agent_pid \(pidKey) --tab=\(record.workspaceId)\(socketPanelOption(record.surfaceId)) --clear-status --require-owned-key\(agentRuntimeMutationOption(statusKey: statusKey, sessionID: record.sessionId, runtimeGeneration: record.runtimeGeneration))",
                        client: client
                    )
                }
                clearedRecords.append(record)
            } catch {
                continue
            }
        }
        try? store.acknowledgeSupersededSessionCleanup(clearedRecords)
    }
}
