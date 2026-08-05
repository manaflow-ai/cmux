import Foundation

/// Describes transcript-derived lifecycle facts used to heal missed hooks.
public enum TranscriptCorroborationFact: Hashable, Sendable {
    /// An assistant turn completed in the transcript.
    case assistantTurnCompleted
    /// A user-authored message was appended to the transcript.
    case userMessageAppended
}
