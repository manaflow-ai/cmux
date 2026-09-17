import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    struct RestoreLaunchAdmissionClaim {
        let workspaceID: String
        let surfaceID: String
        let kind: String
        let sessionID: String
        let claimID: String
    }

    /// Claims the current managed session at the app's fresh process-scan boundary.
    func requireRestoreLaunchAdmission(
        record: RestoreRecord,
        recordSessionID: String?,
        restorePayload: [String: Any],
        client: SocketClient
    ) throws -> RestoreLaunchAdmissionClaim? {
        guard record.mode == AgentRestoreRequestMode.resumeAgent.rawValue ||
            record.mode == AgentRestoreRequestMode.relaunchAgent.rawValue else {
            return nil
        }
        // Same-build apps advertise the admission RPC on the restore payload.
        // An older app paired with a newer standalone CLI keeps its historical
        // behavior instead of receiving a method it cannot understand.
        guard restorePayload["agent_restore_admission_supported"] as? Bool == true else {
            return nil
        }
        guard let sessionID = record.checkpointID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
        !sessionID.isEmpty else {
            if record.source == "agent-hook" {
                throw loggedRestoreError(
                    stage: "admission.identity",
                    detail: "kind=\(record.kind)",
                    message: String(
                        localized: "cli.restore.error.admissionIdentityMissing",
                        defaultValue: "restore: this session's live ownership could not be verified. Run 'cmux restore --surface' again."
                    )
                )
            }
            return nil
        }
        guard let workspaceID = restorePayload["workspace_id"] as? String,
              let surfaceID = restorePayload["surface_id"] as? String else {
            throw loggedRestoreError(
                stage: "admission.identity",
                detail: "kind=\(record.kind)",
                message: String(
                    localized: "cli.restore.error.admissionIdentityMissing",
                    defaultValue: "restore: this session's live ownership could not be verified. Run 'cmux restore --surface' again."
                )
            )
        }
        var lastWriterLockAnswer: [String: Any]?
        let response: [String: Any]
        do {
            response = try RestoreAdmissionRetryPolicy.response(
                onRetry: { attempt in
                    guard attempt == 0 else { return }
                    cliWriteStderr(String(
                        localized: "cli.restore.admission.waiting",
                        defaultValue: "restore: waiting for cmux to verify that this agent session is not already running…"
                    ) + "\n")
                }
            ) {
                let answer = try client.sendV2(
                    method: "agent.restore.admit",
                    params: [
                        "workspace_id": workspaceID,
                        "surface_id": surfaceID,
                        "kind": record.kind,
                        "session_id": sessionID,
                        "record_session_id": recordSessionID ?? sessionID,
                    ]
                )
                // A held Codex writer lock right after a relaunch is usually the
                // previous cmux's Codex still shutting down. Wait a bounded
                // window for it to release before reporting the holder.
                if answer["writer_lock_held"] as? Bool == true,
                   answer["retryable"] as? Bool == true {
                    lastWriterLockAnswer = answer
                    throw RestoreAdmissionRetryPolicy.WriterLockHeld()
                }
                return answer
            }
        } catch is RestoreAdmissionRetryPolicy.WriterLockHeld {
            let answer = lastWriterLockAnswer ?? [:]
            let holderPID = (answer["live_owner_pid"] as? NSNumber)?.int64Value
            throw loggedRestoreError(
                stage: "admission.writer-lock",
                detail: "kind=\(record.kind) session=\(sessionID) lock=\(answer["lock_path"] as? String ?? "none")",
                message: Self.codexWriterRestoreMessage(
                    lockPath: answer["lock_path"] as? String,
                    lockHeld: true,
                    holderPID: holderPID.flatMap { $0 > 0 ? $0 : nil }
                )
            )
        }
        guard response["admitted"] as? Bool == true else {
            if let processID = (response["live_owner_pid"] as? NSNumber)?.int64Value,
               processID > 0 {
                let format = String(
                    localized: "cli.restore.error.liveOwner",
                    defaultValue: "restore: this agent session is already running in process %1$lld. cmux did not start another copy. To take it over here, stop process %1$lld, then run 'cmux restore --surface' again."
                )
                throw loggedRestoreError(
                    stage: "admission.live-owner",
                    detail: "kind=\(record.kind) session=\(sessionID) pid=\(processID)",
                    message: String(
                        format: format,
                        // Keep the PID an unambiguous shell token while the
                        // surrounding diagnostic remains localized.
                        locale: Locale(identifier: "en_US_POSIX"),
                        processID
                    )
                )
            }
            throw loggedRestoreError(
                stage: "admission.concurrent-launch",
                detail: "kind=\(record.kind) session=\(sessionID)",
                message: String(
                    localized: "cli.restore.error.launchPending",
                    defaultValue: "restore: another launch of this agent session is already starting. Wait for it to appear, or retry 'cmux restore --surface'."
                )
            )
        }
        guard let claimID = response["claim_id"] as? String,
              UUID(uuidString: claimID) != nil else {
            throw loggedRestoreError(
                stage: "admission.claim-token",
                detail: "kind=\(record.kind) session=\(sessionID)",
                message: String(
                    localized: "cli.restore.error.admissionIdentityMissing",
                    defaultValue: "restore: this session's live ownership could not be verified. Run 'cmux restore --surface' again."
                )
            )
        }
        return RestoreLaunchAdmissionClaim(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            kind: record.kind,
            sessionID: sessionID,
            claimID: claimID
        )
    }

    /// Bounded retry for a retryable `busy` admission answer.
    ///
    /// The app refuses admission when its ownership-sensitive process scan
    /// cannot settle. Right after a relaunch several restored panes fire their
    /// session-start hooks at once, so that churn is routine for a few
    /// seconds. Giving up immediately left a bare shell whose binding then
    /// retired, and the next relaunch had nothing to resume (#12084).
    enum RestoreAdmissionRetryPolicy {
        /// The app saw Codex's writer lock held with no verified live owner.
        struct WriterLockHeld: Error {}

        /// Bounded wait for a lingering previous Codex to release its lock:
        /// the first four busy delays (0.5 + 1 + 2 + 3 s), short enough that a
        /// genuinely open session is reported within seconds.
        static let writerLockMaximumRetries = 4

        /// A structured v2 `busy` answer that the app marked retryable.
        static func isRetryable(_ error: Error) -> Bool {
            if error is WriterLockHeld { return true }
            guard let error = error as? CLIError else { return false }
            return error.isStructuredProtocolResponse
                && error.v2Code == "busy"
                && error.v2Retryable
        }

        /// `AgentRestoreAdmissionRetry.response` with the CLI's error classifier.
        ///
        /// The busy budget (~45 s) covers hook-store churn; a held writer lock
        /// gets its own shorter budget so the two never compound.
        static func response(
            onRetry: (Int) -> Void = { _ in },
            sending send: () throws -> [String: Any]
        ) throws -> [String: Any] {
            var writerLockAttempts = 0
            return try AgentRestoreAdmissionRetry.response(
                onRetry: onRetry,
                isRetryable: { error in
                    if error is WriterLockHeld {
                        writerLockAttempts += 1
                        return writerLockAttempts <= writerLockMaximumRetries
                    }
                    return isRetryable(error)
                },
                sending: send
            )
        }
    }

    /// Best-effort rollback when preflight or `execve` fails after admission.
    func releaseRestoreLaunchAdmission(
        _ claim: RestoreLaunchAdmissionClaim?,
        client: SocketClient
    ) {
        guard let claim else { return }
        _ = try? client.sendV2(
            method: "agent.restore.release",
            params: [
                "workspace_id": claim.workspaceID,
                "surface_id": claim.surfaceID,
                "kind": claim.kind,
                "session_id": claim.sessionID,
                "claim_id": claim.claimID,
            ]
        )
    }
}
