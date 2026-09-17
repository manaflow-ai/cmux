import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// Outcome of the single pre-exec admission boundary for managed agent restores.
private enum AgentRestoreAdmissionDecision: Sendable {
    case admitted(AgentResumeLaunchGuard.Claim)
    case liveOwner(LiveAgentSessionOwner)
    /// Codex's own kernel writer lock is held for this thread (#12805).
    case writerLockHeld(lockPath: String, holderPID: Int?)
    case concurrentLaunch
    case targetChanged
    case unverifiable(AgentRestoreAdmissionUnverifiableReason)

    var debugLabel: String {
        switch self {
        case .admitted:
            return "admitted"
        case .liveOwner(let owner):
            return "live-owner pid=\(owner.processID)"
        case .writerLockHeld(let lockPath, let holderPID):
            return "writer-lock-held pid=\(holderPID.map(String.init) ?? "unknown") lock=\(lockPath)"
        case .concurrentLaunch:
            return "concurrent-launch"
        case .targetChanged:
            return "target-changed"
        case .unverifiable(let reason):
            return "unverifiable reason=\(reason.rawValue)"
        }
    }
}

/// Why admission could not decide whether the session is already running.
///
/// Each reason carries its own explanation so the CLI shows the user what
/// actually failed. A scan that ran out of time is worth retrying; an
/// unreadable hook store for this agent kind is not.
private enum AgentRestoreAdmissionUnverifiableReason: String, Sendable {
    case scanTimedOut = "scan_timed_out"
    case scanCancelled = "scan_cancelled"
    case hookStoreUnreadable = "hook_store_unreadable"

    var isRetryable: Bool {
        self != .hookStoreUnreadable
    }

    var message: String {
        switch self {
        case .scanTimedOut:
            return String(
                localized: "agentRestore.admission.unavailable.timedOut",
                defaultValue: "cmux could not finish checking whether this agent session is already running before the time limit. Retry 'cmux restore --surface'."
            )
        case .scanCancelled:
            return String(
                localized: "agentRestore.admission.unavailable",
                defaultValue: "cmux could not verify whether this agent session is already running. Retry 'cmux restore --surface'."
            )
        case .hookStoreUnreadable:
            return String(
                localized: "agentRestore.admission.unavailable.hookStoreUnreadable",
                defaultValue: "cmux could not read its saved session records for this agent, so it cannot tell whether the session is already running. Retry 'cmux restore --surface'."
            )
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
        let admissionStart = ContinuousClock.now

        let targetRecordBeforeScan = await v2MainAsync { () -> ControlSurfaceRestoreRecord? in
            guard self.controlRemoteRelayDispatchError(method: request.method, params: request.params) == nil else {
                return nil
            }
            return self.agentRestoreTargetRecord(inputs)
        }
        guard let targetRecordBeforeScan else {
            return Self.agentRestoreAdmissionResponse(
                request: request,
                inputs: inputs,
                decision: .targetChanged,
                startedAt: admissionStart
            )
        }

        let index: RestorableAgentSessionIndex
        switch await SharedLiveAgentIndex.shared.indexForOwnershipDecision() {
        case .index(let refreshedIndex):
            index = refreshedIndex
        case .timedOut:
            return Self.agentRestoreAdmissionResponse(
                request: request,
                inputs: inputs,
                decision: .unverifiable(.scanTimedOut),
                startedAt: admissionStart
            )
        case .cancelled:
            return Self.agentRestoreAdmissionResponse(
                request: request,
                inputs: inputs,
                decision: .unverifiable(.scanCancelled),
                startedAt: admissionStart
            )
        }
        guard index.isComplete(
            forWorkspaceId: inputs.workspaceID,
            panelId: inputs.surfaceID,
            kind: inputs.kind
        ) else {
            return Self.agentRestoreAdmissionResponse(
                request: request,
                inputs: inputs,
                decision: .unverifiable(.hookStoreUnreadable),
                startedAt: admissionStart
            )
        }
        let liveOwner = index.liveSessionOwner(
            kind: inputs.kind,
            sessionID: inputs.sessionID,
            revalidateProcessEvidence: true,
            processArgumentsProvider: { pid in
                CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid)
            },
            processPresenceProvider: { pid in
                guard pid > 0, pid <= Int(Int32.max) else { return .absent }
                return PIDPresence.current(pid: pid_t(pid))
            }
        )
        // cmux's PID scan and Codex's kernel lock are two truths about the same
        // thread. The scan can miss a still-alive previous Codex (hook-store
        // incompleteness, argv mismatch), so consult Codex's lock as well before
        // admitting a second writer. Bounded file and process inspection, off-main.
        let writerLock: (lockPath: String, holderPID: Int?)? = liveOwner == nil
            ? Self.codexWriterLockHeld(record: targetRecordBeforeScan, inputs: inputs)
            : nil
        let decision = await v2MainAsync { () -> AgentRestoreAdmissionDecision in
            guard self.controlRemoteRelayDispatchError(method: request.method, params: request.params) == nil,
                  self.agentRestoreTargetMatches(inputs) else {
                return .targetChanged
            }
            if let writerLock {
                AgentRestoreSuppressionJournal().record(
                    kind: inputs.kind,
                    sessionID: inputs.sessionID,
                    workspaceID: inputs.workspaceID,
                    surfaceID: inputs.surfaceID,
                    processID: writerLock.holderPID ?? 0
                )
                return .writerLockHeld(lockPath: writerLock.lockPath, holderPID: writerLock.holderPID)
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

    /// Probes Codex's writer lock for the account the restore will actually use.
    ///
    /// Returns nil when the lock is free, the record is not a local Codex resume,
    /// or the probe cannot run safely (Codex then remains the final authority).
    private nonisolated static func codexWriterLockHeld(
        record: ControlSurfaceRestoreRecord,
        inputs: AgentRestoreAdmissionInputs,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackHome: String = NSHomeDirectory()
    ) -> (lockPath: String, holderPID: Int?)? {
        guard inputs.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              record.modeRawValue == AgentRestoreRequestMode.resumeAgent.rawValue else {
            return nil
        }
        var launchEnvironment = record.launchCommand?.environment ?? [:]
        launchEnvironment.merge(record.environment) { _, binding in binding }
        let workingDirectory = record.launchCommand?.workingDirectory ?? record.workingDirectory
        let home = CodexHomeResolver().resolve(
            launchEnvironment: launchEnvironment,
            launchWorkingDirectory: workingDirectory,
            launchVerificationHome: record.launchCommand?.verificationHome,
            ambientEnvironment: ambientEnvironment,
            fallbackHomeDirectory: fallbackHome
        )
        let arguments = record.preparedArguments
            ?? record.launchCommand?.arguments
            ?? ["codex", "resume", inputs.sessionID]
        let inspection = CodexWriterRestorePreflight().inspect(
            sessionID: inputs.sessionID,
            arguments: arguments,
            environment: ["CODEX_HOME": home],
            workingDirectory: workingDirectory ?? fallbackHome,
            fallbackHome: fallbackHome
        )
        guard let lock = inspection.lock, lock.state == .active else { return nil }
        return (lock.lockPath, inspection.uniqueOwner.map { Int($0.pid) })
    }

    @MainActor
    private func agentRestoreTargetMatches(
        _ inputs: AgentRestoreAdmissionInputs
    ) -> Bool {
        agentRestoreTargetRecord(inputs) != nil
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
                ]))
            )
        case .writerLockHeld(let lockPath, let holderPID):
            var payload: [String: JSONValue] = [
                "admitted": .bool(false),
                "writer_lock_held": .bool(true),
                "lock_path": .string(lockPath),
                "retryable": .bool(true),
            ]
            if let holderPID, holderPID > 0 {
                payload["live_owner_pid"] = .int(Int64(holderPID))
            }
            return v2Encoder.response(id: request.id, .ok(.object(payload)))
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
        case .unverifiable(let reason):
            return v2Encoder.error(
                id: request.id,
                code: "busy",
                message: reason.message,
                data: .object([
                    "retryable": .bool(reason.isRetryable),
                    "reason": .string(reason.rawValue),
                ])
            )
        }
    }
}
