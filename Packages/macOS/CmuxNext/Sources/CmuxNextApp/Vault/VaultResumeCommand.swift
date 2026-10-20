import CmuxNextHistory

/// The command Copy Resume Command puts on the pasteboard: the agent's resume
/// command, run in the session's directory when it has one, so it works when
/// pasted into any shell.
nonisolated struct VaultResumeCommand: Hashable, Sendable {
    let session: AgentSession

    /// `cd -- '<cwd>' && claude --resume <id>`; nil when cmux does not know how to resume the agent.
    var text: String? {
        guard let resume = session.resumeCommand else { return nil }
        guard let cwd = session.cwd, !cwd.isEmpty else { return resume }
        return "cd -- \(AgentResume.shellQuoted(cwd)) && \(resume)"
    }
}
