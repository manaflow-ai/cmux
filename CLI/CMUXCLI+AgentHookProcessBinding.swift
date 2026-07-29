import Foundation

extension CMUXCLI {
    enum AgentHookProcessBindingSource {
        case ambientTTY
        case liveProcess
    }

    struct AgentHookProcessBindingResult {
        let binding: CallerTerminalBinding?
        let source: AgentHookProcessBindingSource?
        let rejectsAmbientClaim: Bool

        func canReplaceAmbientWorkspace(_ workspaceId: String?) -> Bool {
            guard let workspaceId else { return true }
            return source == .liveProcess || binding?.workspaceId == workspaceId
        }
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
        var attemptedSessionIds: Set<String> = []
        var records = initialRecords
        if records.isEmpty {
            records = (try? store.pendingSupersededSessionCleanupCandidates(for: owner)) ?? []
        }
        while !records.isEmpty {
            attemptedSessionIds.formUnion(records.map(\.sessionId))
            var clearedRecords: [ClaudeHookSessionRecord] = []
            for record in records {
                guard clearAgentSurfaceResumeBinding(
                    client: client,
                    workspaceId: record.workspaceId,
                    surfaceId: record.surfaceId,
                    sessionId: record.sessionId
                ) else {
                    continue
                }
                let pidKey = "\(statusKey).\(record.sessionId)"
                do {
                    _ = try sendV1Command(
                        "clear_agent_pid \(pidKey) --tab=\(record.workspaceId)\(socketPanelOption(record.surfaceId)) --clear-status",
                        client: client
                    )
                    clearedRecords.append(record)
                } catch {
                    continue
                }
            }
            try? store.acknowledgeSupersededSessionCleanup(clearedRecords)
            records = (try? store.pendingSupersededSessionCleanupCandidates(
                for: owner,
                excludingSessionIds: attemptedSessionIds
            )) ?? []
        }
    }
}
