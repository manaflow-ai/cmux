import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Rechecks Codex's kernel writer lock immediately before process replacement.
    ///
    /// The app admission RPC is unavailable when a newer CLI talks to an older
    /// cmux. This final guard keeps that compatibility path from silently
    /// entering Codex's read-only mode. It never waits, removes a lock, or
    /// signals the process that owns it; Codex remains the atomic authority
    /// after this advisory observation.
    func requireCodexWriterAvailable(
        record: RestoreRecord,
        invocation: AgentRestoreInvocation,
        workingDirectory: String
    ) throws {
        guard record.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex",
              record.mode == AgentRestoreRequestMode.resumeAgent.rawValue,
              let sessionID = record.checkpointID,
              !CodexRestoreAccount().usesRemoteProvider(arguments: invocation.arguments) else {
            return
        }
        let home = CodexRestoreAccount().home(
            environment: invocation.environment,
            workingDirectory: workingDirectory,
            fallbackHome: NSHomeDirectory()
        )
        let inspection = CodexWriterLockInspector().inspect(
            sessionID: sessionID,
            codexHome: home
        )
        guard inspection.state == .available else {
            throw loggedRestoreError(
                stage: inspection.state == .active
                    ? "session.writer-lock-held"
                    : "session.writer-check-unavailable",
                detail: "session=\(sessionID)",
                message: String(
                    localized: "agentRestore.admission.unavailable",
                    defaultValue: "cmux could not verify whether this agent session is already running. Retry 'cmux restore --surface'."
                )
            )
        }
    }
}
