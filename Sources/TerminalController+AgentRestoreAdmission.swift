import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// Outcome of the single pre-exec admission boundary for managed agent restores.
private enum AgentRestoreAdmissionDecision: Sendable {
    case admitted(AgentResumeLaunchGuard.Claim)
    case liveOwner(LiveAgentSessionOwner)
    case concurrentLaunch
    case targetChanged
    case indexUnavailable
}

extension TerminalController {
    /// Validates current surface ownership, refreshes live process evidence off-main,
    /// and atomically claims a managed session immediately before the CLI execs it.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func agentRestoreAdmissionResponse(
        _ request: ControlRequest
    ) async -> String {
        guard let inputs = Self.agentRestoreAdmissionInputs(request.params) else {
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "agentRestore.admission.invalid",
                    defaultValue: "Agent restore admission requires a valid workspace, surface, kind, and session."
                )
            )
        }

        let targetMatchesBeforeScan = await v2MainAsync {
            self.agentRestoreTargetMatches(inputs)
        }
        guard targetMatchesBeforeScan else {
            return Self.agentRestoreAdmissionResponse(
                request: request,
                decision: .targetChanged
            )
        }

        guard let index = await SharedLiveAgentIndex.shared.indexRefreshingNow(),
              index.isComplete(
                  forWorkspaceId: inputs.workspaceID,
                  panelId: inputs.surfaceID,
                  kind: inputs.kind
              ) else {
            return Self.agentRestoreAdmissionResponse(
                request: request,
                decision: .indexUnavailable
            )
        }
        let liveOwner = index.liveSessionOwner(
            kind: inputs.kind,
            sessionID: inputs.sessionID,
            revalidateProcessEvidence: true
        )
        let decision = await v2MainAsync { () -> AgentRestoreAdmissionDecision in
            guard self.agentRestoreTargetMatches(inputs) else {
                return .targetChanged
            }
            if let liveOwner {
                AgentRestoreSuppressionJournal().record(
                    kind: inputs.kind,
                    sessionID: inputs.sessionID,
                    workspaceID: inputs.workspaceID,
                    surfaceID: inputs.surfaceID,
                    processID: liveOwner.processID
                )
                return .liveOwner(liveOwner)
            }
            guard let claim = AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(
                kind: inputs.kind,
                sessionId: inputs.sessionID
            ) else {
                return .concurrentLaunch
            }
            return .admitted(claim)
        }
        return Self.agentRestoreAdmissionResponse(
            request: request,
            decision: decision
        )
    }

    /// Releases a pre-exec claim only when the requesting CLI owns its token.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func agentRestoreAdmissionReleaseResponse(
        _ request: ControlRequest
    ) async -> String {
        guard case .string(let rawKind)? = request.params["kind"],
              case .string(let rawSessionID)? = request.params["session_id"],
              case .string(let rawClaimID)? = request.params["claim_id"],
              let claimID = UUID(uuidString: rawClaimID) else {
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "agentRestore.admission.releaseInvalid",
                    defaultValue: "Agent restore claim release requires a valid kind, session, and claim identifier."
                )
            )
        }
        let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !sessionID.isEmpty else {
            return Self.v2Encoder.error(
                id: request.id,
                code: "invalid_params",
                message: String(
                    localized: "agentRestore.admission.releaseInvalid",
                    defaultValue: "Agent restore claim release requires a valid kind, session, and claim identifier."
                )
            )
        }
        let released = await v2MainAsync {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: kind,
                sessionId: sessionID,
                claim: AgentResumeLaunchGuard.Claim(id: claimID)
            )
        }
        return Self.v2Encoder.response(
            id: request.id,
            .ok(.object(["released": .bool(released)]))
        )
    }

    nonisolated private struct AgentRestoreAdmissionInputs: Sendable {
        let workspaceID: UUID
        let surfaceID: UUID
        let kind: String
        let sessionID: String
        let recordSessionID: String
    }

    private nonisolated static func agentRestoreAdmissionInputs(
        _ params: [String: JSONValue]
    ) -> AgentRestoreAdmissionInputs? {
        func string(_ key: String) -> String? {
            guard case .string(let raw)? = params[key] else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let workspaceValue = string("workspace_id"),
              let workspaceID = UUID(uuidString: workspaceValue),
              let surfaceValue = string("surface_id"),
              let surfaceID = UUID(uuidString: surfaceValue),
              let kind = string("kind"),
              let sessionID = string("session_id") else {
            return nil
        }
        return AgentRestoreAdmissionInputs(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            kind: kind,
            sessionID: sessionID,
            recordSessionID: string("record_session_id") ?? sessionID
        )
    }

    @MainActor
    private func agentRestoreTargetMatches(
        _ inputs: AgentRestoreAdmissionInputs
    ) -> Bool {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: inputs.workspaceID,
            surfaceID: inputs.surfaceID,
            paneID: nil
        )
        guard case .result(let snapshot) = controlSurfaceResumeGet(
            routing: routing,
            explicitTargetID: inputs.surfaceID,
            hasResolvedWindowID: false,
            claimCheckpointID: nil,
            claimSource: nil,
            claimUpdatedAt: nil
        ),
        snapshot.workspaceID == inputs.workspaceID,
        snapshot.surfaceID == inputs.surfaceID,
        let record = snapshot.restoreRecord,
        record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue ||
            record.modeRawValue == AgentRestoreRequestMode.relaunchAgent.rawValue,
        record.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            == inputs.kind.trimmingCharacters(in: .whitespacesAndNewlines),
        let checkpointID = record.checkpointID,
        ManagedAgentSessionIdentity.sessionIDsMatch(
            kind: inputs.kind,
            lhs: checkpointID,
            rhs: inputs.sessionID
        ) || ManagedAgentSessionIdentity.sessionIDsMatch(
            kind: inputs.kind,
            lhs: checkpointID,
            rhs: inputs.recordSessionID
        ) else {
            return false
        }
        return true
    }

    private nonisolated static func agentRestoreAdmissionResponse(
        request: ControlRequest,
        decision: AgentRestoreAdmissionDecision
    ) -> String {
        switch decision {
        case .admitted(let claim):
            return v2Encoder.response(
                id: request.id,
                .ok(.object([
                    "admitted": .bool(true),
                    "claim_id": .string(claim.id.uuidString.lowercased()),
                ]))
            )
        case .liveOwner(let owner):
            return v2Encoder.response(
                id: request.id,
                .ok(.object([
                    "admitted": .bool(false),
                    "live_owner_pid": .int(Int64(owner.processID)),
                ]))
            )
        case .concurrentLaunch:
            return v2Encoder.response(
                id: request.id,
                .ok(.object([
                    "admitted": .bool(false),
                    "launch_pending": .bool(true),
                ]))
            )
        case .targetChanged:
            return v2Encoder.error(
                id: request.id,
                code: "conflict",
                message: String(
                    localized: "agentRestore.admission.targetChanged",
                    defaultValue: "The surface restore record changed. Run 'cmux restore --surface' again."
                )
            )
        case .indexUnavailable:
            return v2Encoder.error(
                id: request.id,
                code: "busy",
                message: String(
                    localized: "agentRestore.admission.unavailable",
                    defaultValue: "cmux could not verify whether this agent session is already running. Retry 'cmux restore --surface'."
                ),
                data: .object(["retryable": .bool(true)])
            )
        }
    }
}
