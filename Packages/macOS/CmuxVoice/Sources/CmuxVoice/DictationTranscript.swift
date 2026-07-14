import Foundation

/// Accumulates transcription events into committed text plus a volatile tail.
///
/// The transcript is the deterministic core of the streaming-dictation UX:
/// volatile partials update ``volatileText`` (shown live in the HUD), and
/// finalized segments move into ``committedText``. ``apply(_:)`` returns the
/// exact delta string the caller must type into the insertion target —
/// including an automatically inserted space between adjacent segments — so
/// insertion and display can never drift apart.
///
/// ```swift
/// var transcript = DictationTranscript()
/// transcript.apply(.partial("hel"))          // → nil (HUD-only)
/// transcript.apply(.final("hello"))          // → "hello"
/// transcript.apply(.final("world"))          // → " world"
/// ```
public struct DictationTranscript: Equatable, Sendable {
    /// Text already committed (typed into the insertion target).
    public private(set) var committedText: String = ""

    /// The rolling hypothesis for the utterance currently being spoken.
    public private(set) var volatileText: String = ""

    /// Creates an empty transcript.
    public init() {}

    /// Combined committed + volatile text for HUD display.
    public var displayText: String {
        guard !volatileText.isEmpty else { return committedText }
        guard !committedText.isEmpty else { return volatileText }
        return committedText + (needsSeparator(before: volatileText) ? " " : "") + volatileText
    }

    /// Folds one transcription event into the transcript.
    ///
    /// - Returns: The delta string to insert into the target when the event
    ///   finalized text (with a leading space when two segments would
    ///   otherwise run together), or `nil` for partial updates.
    public mutating func apply(_ event: DictationTranscriptionEvent) -> String? {
        switch event {
        case .partial(let text):
            volatileText = text
            return nil
        case .final(let text):
            volatileText = ""
            return commit(text)
        }
    }

    /// Commits any trailing volatile text at end of session.
    ///
    /// Engines normally finalize their last hypothesis when stopped; this is
    /// the safety net for engines that end their stream with a dangling
    /// partial.
    ///
    /// - Returns: The delta string to insert, or `nil` when there was no
    ///   volatile text.
    public mutating func commitTrailingVolatileText() -> String? {
        guard !volatileText.isEmpty else { return nil }
        let text = volatileText
        volatileText = ""
        return commit(text)
    }

    private mutating func commit(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let delta = needsSeparator(before: text) ? " " + text : text
        committedText += delta
        return delta
    }

    private func needsSeparator(before text: String) -> Bool {
        guard let last = committedText.last, let first = text.first else { return false }
        return !last.isWhitespace && !first.isWhitespace
    }
}
