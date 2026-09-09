import CmuxControlSocket
import Darwin
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

    /// Resolves a generic hook's process identity with live evidence first.
    func resolveAgentHookProcessBinding(
        pid: Int?,
        resolution: AgentProcessBindingResolution,
        client: SocketClient
    ) -> AgentHookProcessBindingResult {
        guard resolution == .controllingTTY else {
            switch liveAgentHookProcessBinding(pid: pid, client: client) {
            case .resolved(let binding):
                return AgentHookProcessBindingResult(binding: binding, source: .liveProcess, rejectsAmbientClaim: false)
            case .unsupported:
                return corroboratedAgentHookProcessBinding(pid: pid, client: client)
            case .failed:
                return AgentHookProcessBindingResult(
                    binding: nil,
                    source: nil,
                    rejectsAmbientClaim: true
                )
            case .notAttempted:
                return corroboratedAgentHookProcessBinding(pid: pid, client: client)
            }
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

    /// Resolves the hook process through the same live PID probe used by
    /// Claude hooks. A sanitized agent hook has no ambient CMUX identity; the
    /// CLI process itself still carries the live controlling TTY, so it is a
    /// safe second candidate when an agent's parent is hidden behind a runner.
    private func liveAgentHookProcessBinding(
        pid: Int?,
        client: SocketClient
    ) -> AgentHookProcessBindingProbe {
        guard !client.isRelayBacked else { return .notAttempted }

        var candidates: [Int] = []
        if let pid, pid > 0 {
            candidates.append(pid)
        }
        let hookPID = Int(getpid())
        if hookPID > 0, !candidates.contains(hookPID) {
            candidates.append(hookPID)
        }
        guard !candidates.isEmpty else { return .notAttempted }

        var sawUnsupported = false
        var sawFailure = false
        for candidate in candidates {
            switch liveAgentPidDeliveryTarget(pid: candidate, client: client) {
            case .resolved(let target):
                return .resolved(
                    CallerTerminalBinding(
                        workspaceId: target.workspaceId,
                        surfaceId: target.surfaceId
                    )
                )
            case .unsupported:
                sawUnsupported = true
            case .failed:
                sawFailure = true
            case .notAttempted:
                continue
            }
        }
        if sawFailure {
            return .failed
        }
        if sawUnsupported {
            return .unsupported
        }
        return .notAttempted
    }

    /// Re-homes a persisted or ambient surface through the shared live owner
    /// map. This keeps moved-pane recovery identical for Claude and generic
    /// hooks without trusting a stale workspace claim.
    func liveAgentHookSurfaceBinding(
        mappedSurfaceId: String?,
        directSurfaceId: String?,
        claimedWorkspaceId: String?,
        client: SocketClient
    ) -> CallerTerminalBinding? {
        var candidates: [String] = []
        if let mappedSurfaceId = nonEmptyClaudeHookIdentifier(mappedSurfaceId) {
            candidates.append(mappedSurfaceId)
        }
        if let directSurfaceId = nonEmptyClaudeHookIdentifier(directSurfaceId),
           !candidates.contains(directSurfaceId) {
            candidates.append(directSurfaceId)
        }
        let claimedWorkspace = nonEmptyClaudeHookIdentifier(claimedWorkspaceId)
        for surfaceId in candidates {
            guard case .resolved(let target) = liveAgentSurfaceDeliveryTarget(
                surfaceId: surfaceId,
                claimedWorkspaceId: claimedWorkspace,
                client: client
            ) else {
                continue
            }
            return CallerTerminalBinding(
                workspaceId: target.workspaceId,
                surfaceId: target.surfaceId
            )
        }
        return nil
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
            let pidKey = "\(statusKey).\(record.sessionId)"
            let isRelayGeneration = record.sessionId.contains("#relay#")
            let processIdentity = isRelayGeneration
                ? nil
                : AgentHookProcessIdentity(record: record)
            guard let cleanupGuard = agentMutationGuard(
                key: statusKey,
                sessionID: record.sessionId,
                expectedPIDKey: isRelayGeneration ? nil : pidKey,
                expectedPID: isRelayGeneration ? nil : record.pid,
                expectedProcessIdentity: processIdentity
            ) else {
                continue
            }
            let resumeClearOutcome = clearAgentSurfaceResumeBindingOutcome(
                client: client,
                workspaceId: record.workspaceId,
                surfaceId: record.surfaceId,
                sessionId: record.sessionId,
                expectedBindingUpdatedAt: record.resumeBindingUpdatedAt,
                agentMutationGuard: cleanupGuard
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
            var clearCommand = "clear_agent_pid \(pidKey) --tab=\(record.workspaceId)"
                + "\(socketPanelOption(record.surfaceId)) --clear-status --require-cleared"
            switch cleanupGuard {
            case .session(_, let sessionID):
                clearCommand += " --session-id=\(socketQuote(sessionID))"
            case .process(_, let guardedPIDKey, let pid, let seconds, let microseconds):
                guard guardedPIDKey == pidKey else { continue }
                clearCommand += " --require-owned-key"
                clearCommand += " --expected-pid=\(pid)"
                clearCommand += " --expected-pid-start-seconds=\(seconds)"
                clearCommand += " --expected-pid-start-microseconds=\(microseconds)"
            }
            do {
                let response = try sendV1Command(clearCommand, client: client)
                guard response == "OK:1" else { continue }
                clearedRecords.append(record)
            } catch {
                continue
            }
        }
        try? store.acknowledgeSupersededSessionCleanup(clearedRecords)
    }
}
