import Foundation

/// A single update from a speech transcriber.
///
/// Engines report a rolling ``partial(_:)`` hypothesis for the utterance
/// currently being spoken, then replace it with one ``final(_:)`` segment
/// once the recognizer commits. Partial text is only ever shown in the
/// dictation HUD; only final segments are inserted into the focused target
/// (a terminal cannot "un-type" a revised hypothesis).
public enum DictationTranscriptionEvent: Equatable, Sendable {
    /// A volatile hypothesis for the in-progress utterance. Replaces any
    /// previous partial text; never inserted into the target.
    case partial(String)

    /// A finalized segment. The in-progress partial (if any) is discarded
    /// and this text is committed to the insertion target.
    case final(String)
}
