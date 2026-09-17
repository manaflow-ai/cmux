import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Refuses to exec a Codex resume while Codex's own writer lock is held.
    ///
    /// Codex keeps a kernel `flock` on `$CODEX_HOME/thread-writer-locks/<thread>.lock`
    /// for the life of the process that owns the thread. A second `codex resume`
    /// against that lock opens read-only ("This conversation is open in another
    /// app"). This guard runs at the exec boundary regardless of whether the app
    /// advertised its admission RPC, using the exact child environment and cwd.
    /// It never removes the lock or signals the holder.
    func guardCodexWriterBeforeRestore(
        sessionID: String?,
        arguments: [String],
        environment: [String: String],
        verificationHome: String? = nil,
        includeOwnerDetails: Bool = true
    ) throws {
        guard let sessionID else { return }
        let preflight = includeOwnerDetails ? CodexWriterRestorePreflight() : CodexWriterRestorePreflight { _ in
            CodexWriterOwnerScan(owners: [], isComplete: false)
        }
        let inspection = preflight.inspect(
            sessionID: sessionID,
            arguments: arguments,
            environment: environment,
            workingDirectory: FileManager.default.currentDirectoryPath,
            verificationHome: verificationHome,
            fallbackHome: NSHomeDirectory()
        )
        guard !inspection.permitsLaunch else { return }
        throw loggedRestoreError(
            stage: inspection.lock?.state == .active ? "session.active-writer" : "session.writer-check-unavailable",
            detail: "session=\(sessionID) lock=\(inspection.lock?.lockPath ?? "none")",
            message: Self.codexWriterRestoreMessage(
                lockPath: inspection.lock?.lockPath,
                lockHeld: inspection.lock?.state == .active,
                holderPID: inspection.uniqueOwner.map { Int64($0.pid) }
            )
        )
    }

    /// A login-shell command may override its parent's home. Only literal
    /// Codex commands carrying their own absolute CODEX_HOME can be preflighted
    /// without changing the captured command or evaluating arbitrary shell code.
    func guardLegacyCodexWriter(
        command: String,
        record: RestoreRecord,
        environment: [String: String],
        includeOwnerDetails: Bool = true
    ) throws {
        let normalizedMode = record.mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = record.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMode == AgentRestoreRequestMode.resumeAgent.rawValue,
              normalizedKind == "codex" else { return }
        guard let sessionID = record.checkpointID,
              let legacy = CodexLegacyRestoreCommand(command: command, sessionID: sessionID) else {
            throw loggedRestoreError(
                stage: "session.legacy-writer-scope",
                detail: "legacy Codex home is not explicit",
                message: String(
                    localized: "cli.restore.error.codexLegacyWriterScope",
                    defaultValue: "restore: cmux cannot safely check whether this older shell-only Codex session is already open. No writer was started. Continue in the original terminal, or start Codex again in this terminal."
                )
            )
        }
        try guardCodexWriterBeforeRestore(
            sessionID: sessionID,
            arguments: legacy.arguments,
            environment: environment.merging(legacy.environment) { _, saved in saved },
            includeOwnerDetails: includeOwnerDetails
        )
    }

    /// One message for the exec-boundary guard and the exhausted admission retry.
    static func codexWriterRestoreMessage(
        lockPath: String?,
        lockHeld: Bool,
        holderPID: Int64?
    ) -> String {
        guard lockHeld else {
            return String(
                localized: "cli.restore.error.codexWriterCheckUnavailable",
                defaultValue: "restore: cmux could not check whether this Codex session is already open, so it did not start another writer. Continue in the original terminal, or check the Codex account configuration and retry 'cmux restore --surface'."
            )
        }
        let posix = Locale(identifier: "en_US_POSIX")
        if let holderPID {
            let format = String(
                localized: "cli.restore.error.codexWriterHeldByProcess",
                defaultValue: "restore: this Codex session is already open in process %1$lld, which holds %2$@. cmux did not start another copy. To take it over here, quit that Codex normally, then run 'cmux restore --surface' again."
            )
            return String(format: format, locale: posix, holderPID, lockPath ?? "")
        }
        let format = String(
            localized: "cli.restore.error.codexWriterHeld",
            defaultValue: "restore: this Codex session is already open in another process, which holds %1$@. cmux did not start another copy. Find the holder with 'lsof %1$@', quit it normally, then run 'cmux restore --surface' again."
        )
        return String(format: format, locale: posix, lockPath ?? "")
    }
}
