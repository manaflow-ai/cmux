/// One bounded prompt boundary awaiting an agent hook.
enum TerminalPromptSubmissionBoundary: Sendable {
    /// Human input submitted at the given ownership generation.
    case human(generation: UInt64)
    /// App-owned input matched by normalized prompt signature.
    case programmatic(
        messageSignature: TerminalPromptMessageSignature,
        source: String,
        confirmsHumanInputSnapshot:
            TerminalPromptInputLedger.HumanInputSnapshot?
    )
    /// Programmatic hook ownership retained after exact source attribution was
    /// evicted. Adjacent retired boundaries coalesce without losing FIFO order.
    case retiredProgrammatic(count: UInt64)
}
