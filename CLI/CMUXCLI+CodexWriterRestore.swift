import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Runs before the binding claim, and repeats cheaply at the exec boundary.
    /// Uses the exact child environment and actual cwd, never verification-only
    /// metadata or the socket's relay status (a relay can still run local Codex).
    func guardCodexWriterBeforeRestore(
        sessionID: String?,
        arguments: [String],
        environment: [String: String],
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
            fallbackHome: NSHomeDirectory()
        )
        guard !inspection.permitsLaunch else { return }
        throw loggedRestoreError(
            stage: inspection.lock?.state == .active ? "session.active-writer" : "session.writer-check-unavailable",
            detail: "session=\(sessionID)",
            message: CodexWriterRestoreMessage(sessionID: sessionID, inspection: inspection).text
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
        guard record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              record.kind.lowercased() == "codex" else { return }
        guard let sessionID = record.checkpointID,
              let legacy = CodexLegacyRestoreCommand(command: command, sessionID: sessionID) else {
            throw loggedRestoreError(
                stage: "session.legacy-writer-scope",
                detail: "legacy Codex home is not explicit",
                message: String(
                    localized: "codex.restore.legacyScopeUnavailable",
                    defaultValue: "cmux cannot safely check ownership for this older shell-only Codex restore. No writer was started. Continue in the original terminal, or exit that session normally and resume it with Codex using the original CODEX_HOME and session ID."
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
}
