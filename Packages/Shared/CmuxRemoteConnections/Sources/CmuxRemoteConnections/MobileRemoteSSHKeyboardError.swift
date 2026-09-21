/// Failures from transient keyboard-interactive authentication.
public enum MobileRemoteSSHKeyboardError: Error, Equatable, Sendable {
    /// A prompt or challenge exceeded bounded input limits.
    case invalidPrompt
    /// A challenge contained unsupported metadata or too many prompts.
    case invalidChallenge
    /// The responder returned a different number of answers than prompts.
    case answerCountMismatch
}
