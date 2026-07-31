/// One ordered prompt boundary awaiting confirmation from an agent hook.
enum TerminalPromptSubmissionBoundary: Sendable {
    /// Physical terminal input submitted at the given human-input generation.
    case human(generation: UInt64)
    /// One complete app-owned prompt transaction.
    case programmatic(ProgrammaticPromptHookRecording)
}
