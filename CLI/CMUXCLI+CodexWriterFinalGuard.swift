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
        invocation: AgentRestoreInvocation,
        workingDirectory: String
    ) throws {
        guard let sessionID = invocation.codexResumeSessionID,
              !CodexRestoreAccount().usesRemoteProvider(arguments: invocation.arguments) else {
            return
        }
        let home = CodexRestoreAccount().home(
            environment: invocation.environment,
            workingDirectory: workingDirectory,
            fallbackHome: NSHomeDirectory()
        )
        var inspection = CodexWriterLockInspector().inspect(
            sessionID: sessionID,
            codexHome: home
        )
        var candidates: [CodexWriterProcessInspector.Candidate] = []
        if inspection.state == .active {
            let observed = inspection
            candidates = CodexWriterProcessInspector().candidates(for: observed)
            inspection = CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: home)
            if !inspection.deviceAndInodeMatch(observed) { candidates = [] }
        }
        guard inspection.state == .available else {
            throw loggedRestoreError(
                stage: inspection.state == .active
                    ? "session.writer-lock-held"
                    : "session.writer-check-unavailable",
                detail: "session=\(sessionID)",
                message: inspection.state == .active ? CodexWriterRestoreNotice().message(candidates: candidates) : String(
                    localized: "agentRestore.admission.unavailable",
                    defaultValue: "cmux could not verify whether this agent session is already running. Retry 'cmux restore --surface'."
                )
            )
        }
    }
}
