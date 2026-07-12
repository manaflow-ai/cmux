import Foundation

/// Describes an interactive agent prompt that marks both readiness and the end of a response.
public struct PromptLineTurnDetectionConfiguration: Equatable, Sendable {
    /// The exact logical-line prompt emitted by the agent while it waits for input.
    public let prompt: String

    /// The time an exact prompt line must remain unchanged before confirmation.
    public let confirmationDelay: Duration

    let promptBytes: [UInt8]

    /// Creates prompt-line turn detection for an exact prompt string.
    ///
    /// - Parameters:
    ///   - prompt: A non-empty prompt, such as `">>> "`.
    ///   - confirmationDelay: The debounce interval used to reject response lines
    ///     that merely begin with the prompt text.
    public init(
        prompt: String,
        confirmationDelay: Duration = .milliseconds(500)
    ) {
        precondition(!prompt.isEmpty, "A prompt-line detector requires a non-empty prompt")
        precondition(confirmationDelay > .zero, "A prompt-line detector requires a positive confirmation delay")
        self.prompt = prompt
        self.confirmationDelay = confirmationDelay
        self.promptBytes = Array(prompt.utf8)
    }
}
