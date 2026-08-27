import Foundation

/// Accumulates transcription events into committed text plus a volatile tail.
///
/// The transcript is the deterministic core of the streaming-dictation UX:
/// volatile partials update ``volatileText`` (shown live in the HUD), and
/// finalized segments move into ``committedText``. ``apply(_:)`` returns the
/// exact delta string the caller must type into the insertion target —
/// including a boundary-aware separator between adjacent segments — so
/// insertion and display can never drift apart across writing systems.
///
/// ```swift
/// var transcript = DictationTranscript()
/// transcript.apply(.partial("hel"))          // → nil (HUD-only)
/// transcript.apply(.final("hello"))          // → "hello"
/// transcript.apply(.final("world"))          // → " world"
/// ```
public struct DictationTranscript: Equatable, Sendable {
    /// Recent text already committed (typed into the insertion target).
    public private(set) var committedText: String = ""

    /// The rolling hypothesis for the utterance currently being spoken.
    public private(set) var volatileText: String = ""

    /// Incremental tail used by the HUD; the full committed transcript remains
    /// available for insertion bookkeeping without rebuilding it on every
    /// partial update.
    private var committedDisplayTail = ""

    private static let displayTailLimit = 512
    private static let committedTextLimit = 4_096

    /// Creates an empty transcript.
    public init() {}

    /// Combined committed + volatile text for HUD display.
    public var displayText: String {
        let volatileTail = String(volatileText.suffix(Self.displayTailLimit))
        guard !volatileTail.isEmpty else { return committedDisplayTail }
        guard !committedDisplayTail.isEmpty else { return volatileTail }
        let separator = needsSeparator(before: volatileText) ? " " : ""
        return String((committedDisplayTail + separator + volatileTail).suffix(Self.displayTailLimit))
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
            // A final result, including an empty one, is authoritative: an
            // empty final explicitly revokes the preceding volatile guess.
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
        committedText = String(
            (committedText + delta).suffix(Self.committedTextLimit)
        )
        committedDisplayTail = String(
            (committedDisplayTail + delta).suffix(Self.displayTailLimit)
        )
        return delta
    }

    private func needsSeparator(before text: String) -> Bool {
        guard let last = committedText.last, let first = text.first,
              !last.isWhitespace, !first.isWhitespace else { return false }

        // Punctuation and symbols carry their own boundary. In particular,
        // avoid producing `word ,` or `( word` when a recognizer emits those
        // as separate finalized segments.
        guard !first.isPunctuation, !first.isSymbol,
              !isOpeningPunctuation(last) else { return false }

        // CJK, Hangul, and several Southeast-Asian scripts conventionally
        // separate words without ASCII spaces. Suppress an inserted space
        // when both adjacent segments use one of those scripts. A punctuation
        // mark next to such a script is also kept tight (for example `世界。`)
        // while Latin word boundaries retain the existing space behavior.
        if usesNonSpacingScript(last) && usesNonSpacingScript(first) {
            return false
        }
        if last.isPunctuation && usesNonSpacingScript(first) {
            return false
        }
        return true
    }

    private func isOpeningPunctuation(_ character: Character) -> Bool {
        if character == "\"" || character == "'" {
            // ASCII quotes have no opening/closing Unicode category. Treat a
            // quote after a word as closing so `James' Bond` and `"hi" world`
            // retain their normal word boundary; a quote at the start of a
            // segment (or after whitespace/opening punctuation) is opening.
            guard let preceding = committedText.dropLast().last else { return true }
            return preceding.isWhitespace || isOpeningBracket(preceding)
        }
        return isOpeningBracket(character)
    }

    private func isOpeningBracket(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .openPunctuation, .initialPunctuation:
                return true
            default:
                return false
            }
        }
    }

    private func usesNonSpacingScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            // Hiragana, Katakana, Bopomofo, and Han ideographs.
            case 0x2E80...0x2FFF,
                 0x3000...0x30FF,
                 0x3100...0x312F,
                 0x31A0...0x31FF,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0xFE30...0xFE4F,
                 0x20000...0x323AF:
                return true
            // Hangul jamo and syllables.
            case 0x1100...0x11FF,
                 0x3130...0x318F,
                 0xA960...0xA97F,
                 0xAC00...0xD7FF:
                return true
            // Thai, Lao, Khmer, and Myanmar script blocks.
            case 0x0E00...0x0E7F,
                 0x0E80...0x0EFF,
                 0x1000...0x109F,
                 0x1780...0x17FF,
                 0xA9E0...0xA9FF,
                 0xAA60...0xAA7F:
                return true
            default:
                return false
            }
        }
    }
}
