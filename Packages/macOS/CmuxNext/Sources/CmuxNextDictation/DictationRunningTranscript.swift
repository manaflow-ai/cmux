import Foundation

/// Turns an engine that reports its whole transcript so far (a confirmed
/// part and a volatile tail, both growing) into ``DictationTranscriptionEvent``s:
/// each newly confirmed word becomes one ``DictationTranscriptionEvent/final(_:)``
/// and the tail a ``DictationTranscriptionEvent/partial(_:)``.
///
/// Committed text is already typed into the target and cannot be taken back,
/// so a later rewrite of confirmed words is ignored: only words past the
/// count already committed are emitted, and nothing is ever typed twice.
public struct DictationRunningTranscript: Equatable, Sendable {
    private var committedWords = 0
    private var lastPartial = ""

    public init() {}

    /// The events for the engine's latest `confirmed` and `volatile` text.
    public mutating func update(confirmed: String, volatile: String) -> [DictationTranscriptionEvent] {
        var events: [DictationTranscriptionEvent] = []
        let words = Self.words(confirmed)
        if words.count > committedWords {
            events.append(.final(words[committedWords...].joined(separator: " ")))
            committedWords = words.count
            lastPartial = ""
        }
        let partial = Self.words(volatile).joined(separator: " ")
        if partial != lastPartial {
            events.append(.partial(partial))
            lastPartial = partial
        }
        return events
    }

    /// The last event when the engine stops: everything in `text` (its whole
    /// final transcript) past the words already committed, as one final.
    /// An empty final still clears a dangling partial.
    public mutating func finish(text: String) -> DictationTranscriptionEvent {
        let words = Self.words(text)
        let rest = words.count > committedWords ? words[committedWords...].joined(separator: " ") : ""
        committedWords = max(committedWords, words.count)
        lastPartial = ""
        return .final(rest)
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
