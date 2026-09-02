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
    /// An exact app-owned hook already matched while human input remained
    /// pending; a duplicate signature must not consume that human boundary.
    case confirmedProgrammatic(
        messageSignature: TerminalPromptMessageSignature
    )
    /// Programmatic hook ownership retained after exact source attribution was
    /// evicted. Adjacent retired boundaries coalesce without losing FIFO order.
    case retiredProgrammatic(count: UInt64)
}
