/// One bounded prompt boundary awaiting an agent hook.
enum TerminalPromptSubmissionBoundary: Sendable {
    /// Human input submitted at the given ownership generation.
    case human(generation: UInt64)
    /// App-owned input matched by normalized prompt signature.
    case programmatic(
        messageSignature: TerminalPromptMessageSignature,
        source: String
    )
}
