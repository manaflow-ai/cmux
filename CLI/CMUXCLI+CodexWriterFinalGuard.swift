import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
    /// Rechecks Codex's kernel writer lock immediately before process replacement.
    ///
    /// The app admission RPC is unavailable when a newer CLI talks to an older
    /// cmux. This final guard keeps that compatibility path from silently
    /// entering Codex's read-only mode. It waits only a bounded time while
    /// Codex changes its lock namespace, and never removes a lock or signals
    /// the process that owns it; Codex remains the atomic authority after
    /// this advisory observation.
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
        // Another Codex starting during a relaunch can hold the namespace
        // briefly; retry that alone so it is not mistaken for an owner.
        let probe = { CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: home) }
        var inspection = CodexWriterLockSettle().inspection(probe: probe)
        var candidates: [CodexWriterProcessInspector.Candidate] = []
        if inspection.state == .active {
            let observed = inspection
            candidates = CodexWriterProcessInspector().candidates(for: observed)
            inspection = CodexWriterLockSettle().inspection(probe: probe)
            if !inspection.deviceAndInodeMatch(observed) { candidates = [] }
        }
        switch inspection.state {
        case .available:
            return
        case .active:
            throw loggedRestoreError(
                stage: "session.writer-lock-held",
                detail: "session=\(sessionID)",
                message: CodexWriterRestoreNotice().message(candidates: candidates)
            )
        case .changing:
            throw loggedRestoreError(
                stage: "session.writer-lock-changing",
                detail: "session=\(sessionID)",
                message: String(
                    localized: "agentRestore.writerLock.changing",
                    defaultValue: "Codex was still updating its session locks, so cmux could not confirm this conversation is free. Retry 'cmux restore --surface'."
                )
            )
        case .unavailable:
            throw loggedRestoreError(
                stage: "session.writer-check-unavailable",
                detail: "session=\(sessionID)",
                message: String(
                    localized: "agentRestore.writerLock.unreadable",
                    defaultValue: "cmux could not read this conversation's Codex session lock, so it could not confirm the conversation is free. Retry 'cmux restore --surface'."
                )
            )
        }
    }
}
