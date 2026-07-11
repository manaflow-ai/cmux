import Foundation

/// Describes an interactive agent prompt that marks both readiness and the end of a response.
public struct PromptLineTurnDetectionConfiguration: Equatable, Sendable {
    /// The exact logical-line prompt emitted by the agent while it waits for input.
    public let prompt: String

    let promptBytes: [UInt8]

    /// Creates prompt-line turn detection for an exact prompt string.
    ///
    /// - Parameter prompt: A non-empty prompt, such as `">>> "`.
    public init(prompt: String) {
        precondition(!prompt.isEmpty, "A prompt-line detector requires a non-empty prompt")
        self.prompt = prompt
        self.promptBytes = Array(prompt.utf8)
    }
}
