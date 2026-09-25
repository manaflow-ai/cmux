import CMUXAgentLaunch
import CmuxFoundation
import CmuxControlSocket
import Foundation

/// Outcome of the single pre-exec admission boundary for managed agent restores.
private enum AgentRestoreAdmissionDecision: Sendable {
    case admitted(AgentResumeLaunchGuard.Claim)
    case liveOwner(LiveAgentSessionOwner)
    case concurrentLaunch
    case targetChanged
    case recovering

    var debugLabel: String {
        switch self {
        case .admitted:
            return "admitted"
        case .liveOwner(let owner):
            return "live-owner pid=\(owner.processID)"
        case .concurrentLaunch:
            return "concurrent-launch"
        case .targetChanged:
            return "target-changed"
        case .recovering:
            return "recovering"
        }
    }
}

extension TerminalController {
    /// Validates current surface ownership, refreshes live process evidence off-main,
    /// and atomically claims a managed session immediately before the CLI execs it.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func agentRestoreAdmissionResponse(
        _ request: ControlRequest
    ) async throws -> String {
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
        let admissionStart = ContinuousClock.now

        let record = try await v2MainAsync { () -> ControlSurfaceRestoreRecord? in
            guard self.controlRemoteRelayDispatchError(method: request.method, params: request.params) == nil else { return nil }
            return self.agentRestoreTargetRecord(inputs)
        }
        guard let record else {
            return Self.agentRestoreAdmissionResponse(
                request: request,
                inputs: inputs,
                decision: .targetChanged,
                startedAt: admissionStart
            )
        }

        let writer = AgentRestoreCodexEvidence().inspect(
            record: record, sessionID: inputs.sessionID, effectiveHome: inputs.codexHome
        )
        let liveOwner: LiveAgentSessionOwner?
        let indexComplete: Bool
        if inputs.kind == "codex", writer != nil {
            let evidence = await codexRestoreHookEvidence.load(sessionID: inputs.sessionID) { pid in
                guard pid > 0, pid <= Int(Int32.max) else { return nil }
                return AgentPIDProcessIdentity(pid: pid_t(pid))
            }
            liveOwner = evidence.owner
            indexComplete = evidence.isComplete
        } else {
            switch await SharedLiveAgentIndex.shared.indexForOwnershipDecision() {
            case .index(let index):
                liveOwner = index.liveSessionOwner(
                    kind: inputs.kind, sessionID: inputs.sessionID, revalidateProcessEvidence: true,
                    processArgumentsProvider: { CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0) },
                    processPresenceProvider: { pid in
                        guard pid > 0, pid <= Int(Int32.max) else { return .absent }
                        return PIDPresence.current(pid: pid_t(pid))
                    }
                )
                indexComplete = index.isComplete(
                    forWorkspaceId: inputs.workspaceID, panelId: inputs.surfaceID, kind: inputs.kind
                )
            case .timedOut, .cancelled:
                liveOwner = nil
                indexComplete = false
            }
        }
        guard !Task.isCancelled else {
            return Self.agentRestoreAdmissionResponse(
                request: request, inputs: inputs, decision: .targetChanged, startedAt: admissionStart
            )
        }
        let evidenceDecision = inputs.launchLeasePending ? .refreshEvidence : AgentRestoreEvidencePolicy().decision(
            hasLiveOwner: liveOwner != nil,
            indexComplete: indexComplete,
            writerLock: writer?.state
        )
        let decision = try await v2MainAsync { () -> AgentRestoreAdmissionDecision in
            guard self.controlRemoteRelayDispatchError(method: request.method, params: request.params) == nil,
                  self.agentRestoreTargetRecord(inputs) == record else { return .targetChanged }
            if evidenceDecision != .claimLaunch {
                let changed = self.presentAgentRestoreRecovery(
                    workspaceID: inputs.workspaceID, surfaceID: inputs.surfaceID,
                    state: liveOwner.map { .liveOwner(kind: inputs.kind, processID: $0.processID) } ?? .checking
                )
                if changed, let liveOwner {
                    AgentRestoreSuppressionJournal().record(
                        kind: inputs.kind, sessionID: inputs.sessionID,
                        workspaceID: inputs.workspaceID, surfaceID: inputs.surfaceID,
                        processID: liveOwner.processID
                    )
                }
                return liveOwner.map(AgentRestoreAdmissionDecision.liveOwner) ?? .recovering
            }
            guard let claim = AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(
                kind: inputs.kind, sessionId: inputs.sessionID
            ) else { return .concurrentLaunch }
            self.presentAgentRestoreRecovery(
                workspaceID: inputs.workspaceID, surfaceID: inputs.surfaceID, state: nil
            )
            return .admitted(claim)
        }
        // The CLI keeps the original restore operation alive. Each subsequent
        // request is paced by kernel evidence or the bounded RPC deadline.
        if inputs.waitForChange {
            switch decision {
            case .liveOwner, .recovering, .concurrentLaunch:
                let kind = RestorableAgentKind(rawValue: inputs.kind)
                let hookPath = kind?.hookStoreFileURL(homeDirectory: NSHomeDirectory())
                let lockDirectory = writer.map { URL(fileURLWithPath: $0.lockPath).deletingLastPathComponent().path }
                await AgentRestoreEvidenceObservation().wait(
                    process: liveOwner?.processIdentity,
                    paths: [hookPath?.deletingLastPathComponent().path, lockDirectory, writer?.lockPath].compactMap { $0 }
                )
            case .admitted, .targetChanged:
                break
            }
        }
        return Self.agentRestoreAdmissionResponse(
            request: request,
            inputs: inputs,
            decision: decision,
            startedAt: admissionStart
        )
    }

    /// Releases a pre-exec claim only when the requesting CLI owns its token.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func agentRestoreAdmissionReleaseResponse(
        _ request: ControlRequest
    ) async throws -> String {
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
        let released = try await v2MainAsync {
            guard self.controlRemoteRelayDispatchError(method: request.method, params: request.params) == nil else { return false }
            return AgentResumeLaunchGuard.shared.releaseResumeLaunch(
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
            recordSessionID: string("record_session_id") ?? sessionID,
            codexHome: params["codex_home"].flatMap { if case .string(let home) = $0 { return home }; return nil },
            waitForChange: boolean("wait_for_change", in: params),
            launchLeasePending: boolean("launch_lease_pending", in: params)
        )
    }

    private nonisolated static func boolean(_ key: String, in params: [String: JSONValue]) -> Bool {
        if case .bool(let value)? = params[key] { return value }
        return false
    }

    @MainActor
    private func agentRestoreTargetRecord(
        _ inputs: AgentRestoreAdmissionInputs
    ) -> ControlSurfaceRestoreRecord? {
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
            return nil
        }
        return record
    }

    private nonisolated static func agentRestoreAdmissionResponse(
        request: ControlRequest,
        inputs: AgentRestoreAdmissionInputs,
        decision: AgentRestoreAdmissionDecision,
        startedAt: ContinuousClock.Instant
    ) -> String {
#if DEBUG
        let elapsed = startedAt.duration(to: .now).components
        let elapsedMilliseconds = elapsed.seconds * 1_000
            + elapsed.attoseconds / 1_000_000_000_000_000
        cmuxDebugLog(
            "agentRestore.admit kind=\(inputs.kind) session=\(inputs.sessionID) surface=\(inputs.surfaceID.uuidString) decision=\(decision.debugLabel) ms=\(elapsedMilliseconds)"
        )
#endif
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
                    "recovering": .bool(true),
                ]))
            )
        case .concurrentLaunch:
            return v2Encoder.response(
                id: request.id,
                .ok(.object([
                    "admitted": .bool(false),
                    "launch_pending": .bool(true),
                    "recovering": .bool(true),
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
        case .recovering:
            return v2Encoder.response(
                id: request.id,
                .ok(.object(["admitted": .bool(false), "recovering": .bool(true)]))
            )
        }
    }
}
