import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Checks the exact child account independently of the app's RPC capabilities.
    func guardCodexWriterBeforeRestore(
        sessionID: String?,
        arguments: [String],
        environment: [String: String],
        waitForExit: Bool = true
    ) throws {
        guard let sessionID else { return }
        let preflight = CodexWriterRestorePreflight()
        let inspect = {
            preflight.inspect(
                sessionID: sessionID,
                arguments: arguments,
                environment: environment,
                workingDirectory: FileManager.default.currentDirectoryPath,
                fallbackHome: NSHomeDirectory()
            )
        }
        do {
            try preflight.waitUntilAvailable(
                delays: waitForExit ? CodexWriterRestorePreflight.retryDelaysSeconds : [],
                onRetry: { attempt in
                    guard attempt == 0 else { return }
                    let message = String(localized: "codex.restore.waitingForWriter", defaultValue: "restore: waiting for the previous Codex writer to release this conversation…")
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                },
                inspect: inspect
            )
        } catch let blocked as CodexWriterRestorePreflight.Blocked {
            let candidates = waitForExit ? CodexWriterProcessInspector().candidates(for: blocked.inspection) : []
            // The writer may have exited during discovery. Recheck before blocking,
            // and attach diagnostics only to the same still-locked inode.
            guard let current = waitForExit ? inspect() : blocked.inspection,
                  current.state != .available else { return }
            let sameLock = current.state == .active && current.deviceAndInodeMatch(blocked.inspection)
            throw loggedRestoreError(
                stage: current.state == .active ? "session.active-writer" : "session.writer-check-unavailable",
                detail: "session=\(sessionID)",
                message: CodexWriterRestoreMessage(
                    inspection: current,
                    candidates: sameLock ? candidates : []
                ).text
            )
        }
    }

    /// Login-shell startup can change accounts, so ambiguous legacy commands fail closed.
    func guardLegacyCodexWriter(
        command: String,
        record: RestoreRecord,
        environment: [String: String],
        waitForExit: Bool = true
    ) throws {
        guard record.mode.trimmingCharacters(in: .whitespacesAndNewlines) == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex" else { return }
        guard let sessionID = record.checkpointID,
              let legacy = CodexLegacyRestoreCommand(command: command, sessionID: sessionID) else {
            throw loggedRestoreError(
                stage: "session.legacy-writer-scope",
                message: String(localized: "codex.restore.legacyScopeUnavailable", defaultValue: "cmux cannot safely check ownership for this older shell-only Codex restore. Start Codex with the intended account and resume this conversation manually.")
            )
        }
        try guardCodexWriterBeforeRestore(
            sessionID: sessionID,
            arguments: legacy.arguments,
            environment: environment.merging(legacy.environment) { _, saved in saved },
            waitForExit: waitForExit
        )
    }
}
