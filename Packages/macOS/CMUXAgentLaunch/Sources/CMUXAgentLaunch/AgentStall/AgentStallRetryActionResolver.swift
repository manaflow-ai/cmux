/// Resolves provider retry actions to the same key sequence a person uses.
public struct AgentStallRetryActionResolver: Sendable {
    /// Creates the built-in provider action resolver.
    public init() {}

    /// Returns ordered PTY input for one supported provider action.
    ///
    /// Up recalls the previous submitted prompt in both managed Claude Code and
    /// Codex sessions; Return submits it again. The terminal input parser converts the CSI
    /// sequence back into a real Up key, so Ghostty re-encodes it for the
    /// terminal's current cursor-key mode.
    public func input(for actionID: String, provider: String) -> String? {
        let canonicalProvider = AgentStallClassifier.canonicalProvider(provider)
        guard canonicalProvider == "claude" || canonicalProvider == "codex" else {
            return nil
        }
        switch actionID {
        case "replayLastPrompt":
            return "\u{001B}[A\r"
        default:
            return nil
        }
    }
}
