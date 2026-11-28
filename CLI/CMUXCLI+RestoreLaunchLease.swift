import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Serializes the preflight-to-exec handoff across stable and nightly instances.
    func acquireRestoreLaunchLease(
        record: RestoreRecord,
        invocation: AgentRestoreInvocation,
        restorePayload: [String: Any],
        client: SocketClient,
        workingDirectory: String
    ) throws -> AgentRestoreLaunchLease? {
        guard record.kind == "codex", record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              let sessionID = record.checkpointID,
              !CodexRestoreAccount().usesRemoteProvider(arguments: invocation.arguments) else { return nil }
        let home = CodexRestoreAccount().home(
            environment: invocation.environment, workingDirectory: workingDirectory,
            fallbackHome: NSHomeDirectory()
        )
        let inspection = CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: home)
        let lease = try AgentRestoreLaunchLease(
            directory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".cmuxterm/agent-restore-launches", isDirectory: true),
            account: inspection.codexHome, sessionID: sessionID
        )
        if try !lease.tryAcquire() {
            var processID = lease.liveOwnerProcessID.map(Int64.init)
            // End the app's checking state, without claiming or queuing a
            // second launch. The lease can supply an owner before hooks arrive.
            if let workspaceID = restorePayload["workspace_id"] as? String,
               let surfaceID = restorePayload["surface_id"] as? String,
               restorePayload["agent_restore_admission_supported"] as? Bool == true {
                let deadline = Date.now.addingTimeInterval(2)
                var params: [String: Any] = [
                    "workspace_id": workspaceID, "surface_id": surfaceID,
                    "kind": record.kind, "session_id": sessionID,
                    "codex_home": home, "launch_lease_pending": true
                ]
                let response = (try? sendRestoreAdmission(
                    params: &params, restorePayload: restorePayload, client: client,
                    responseTimeout: 2, deadline: deadline
                )) ?? [:]
                processID = processID ?? (response["live_owner_pid"] as? NSNumber)?.int64Value
                // Older apps do not understand the pending hint. Return any
                // claim they issued before rejecting this contender.
                if let claimID = response["claim_id"] as? String {
                    // A late admission reply must still allow the rollback to
                    // be sent, without extending the admission/retarget budget.
                    releaseRestoreLaunchAdmission(RestoreLaunchAdmissionClaim(
                        workspaceID: (params["workspace_id"] as? String) ?? workspaceID, surfaceID: surfaceID,
                        kind: record.kind, sessionID: sessionID, claimID: claimID
                    ), client: client, deadline: Date.now.addingTimeInterval(0.5))
                }
            }
            throw restoreLaunchConflictError(kind: record.kind, sessionID: sessionID, processID: processID)
        }
        return lease
    }

    /// Hands the lease to a watcher bound to this process, immediately before exec.
    func transferRestoreLaunchLease(_ lease: AgentRestoreLaunchLease) throws {
        guard let executable = resolvedExecutableURL()?.path else { throw POSIXError(.ENOENT) }
        try lease.transferToExitWatcher(
            executablePath: executable,
            arguments: [executable, "__restore-lease-watch", String(getpid())]
        )
    }

    /// Internal watcher process: holds the inherited lease until the restoring process exits.
    func runRestoreLeaseWatcher(commandArgs: [String]) -> Never {
        guard let raw = commandArgs.first, let processID = pid_t(raw), processID > 1 else { exit(64) }
        exit(AgentRestoreLaunchLease.runExitWatcher(processID: processID) ? 0 : 1)
    }
}
