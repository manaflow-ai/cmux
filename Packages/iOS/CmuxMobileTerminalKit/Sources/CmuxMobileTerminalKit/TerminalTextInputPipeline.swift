import Foundation

/// Pure transform deciding what a soft-keyboard text change should commit.
///
/// While the IME is composing (marked text present) nothing is committed and
/// the buffer keeps the in-progress text. Once composition ends, the full text
/// commits and the buffer clears. Extracted verbatim from the iOS input view
/// so the commit policy is testable without a `UITextView`.
public struct TerminalTextInputPipeline {
    private init() {}

    /// The outcome of processing a text change.
    public struct Result: Equatable, Sendable {
        /// Text to send to the terminal, or `nil` when nothing commits.
        public var committedText: String?
        /// The text the input buffer should hold after this change.
        public var nextBufferText: String

        /// Creates a result.
        /// - Parameters:
        ///   - committedText: Text to commit, if any.
        ///   - nextBufferText: The buffer text after the change.
        public init(committedText: String?, nextBufferText: String) {
            self.committedText = committedText
            self.nextBufferText = nextBufferText
        }
    }

    /// Decides what to commit for a text change.
    ///
    /// - Parameters:
    ///   - text: The current full text of the input field.
    ///   - isComposing: Whether the IME is mid-composition (marked text present).
    /// - Returns: The commit decision and next buffer state.
    public static func process(text: String, isComposing: Bool) -> Result {
        guard !isComposing else {
            return Result(committedText: nil, nextBufferText: text)
        }
        guard !text.isEmpty else {
            return Result(committedText: nil, nextBufferText: "")
        }
        return Result(committedText: text, nextBufferText: "")
    }
}
