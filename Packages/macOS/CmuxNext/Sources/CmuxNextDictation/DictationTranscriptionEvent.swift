import Foundation

/// One update from a speech engine: a rolling ``partial(_:)`` hypothesis for
/// the utterance being spoken, replaced by one ``final(_:)`` segment once the
/// recognizer commits it.
public enum DictationTranscriptionEvent: Equatable, Sendable {
    /// Replaces the previous partial text.
    case partial(String)
    /// Commits a segment; the partial is discarded.
    case final(String)
}
