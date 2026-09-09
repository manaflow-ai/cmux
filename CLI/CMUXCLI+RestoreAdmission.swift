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
        let response = try client.sendV2(
            method: "agent.restore.admit",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "kind": record.kind,
                "session_id": sessionID,
                "record_session_id": recordSessionID ?? sessionID,
            ]
        )
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
