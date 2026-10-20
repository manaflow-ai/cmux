/// Whether an agent's session store is keyed by the directory the agent was launched in.
///
/// This decides whether `<agent> --resume <id>` is sensitive to the directory it runs from, which in
/// turn drives how cmux chooses the working directory when it restores a session.
public enum AgentCwdNamespacing: Sendable, Equatable {
    /// The store is keyed by a directory derived from the launch cwd (Claude `projects/<encode(cwd)>/`,
    /// plus the Grok/Pi/Gemini/Cursor/Qoder cwd-keyed buckets). Resuming from a different directory
    /// looks in the wrong namespace and fails with "No conversation found". Kinds whose layout has not
    /// been verified are treated as ``byDirectory`` because preferring the launch cwd is never worse
    /// for resume lookup.
    case byDirectory

    /// Sessions are addressed by id and the cwd is recorded inside the session file (Codex, OpenCode,
    /// Amp, Antigravity, Rovo Dev, Hermes). Resume works from any directory, so the runtime cwd can be
    /// kept and the agent reopens where it was working.
    case cwdInFile
}
