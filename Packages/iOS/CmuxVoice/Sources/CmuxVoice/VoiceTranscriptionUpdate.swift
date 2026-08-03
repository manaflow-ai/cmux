import Foundation

/// A transcription update emitted by a voice engine.
public enum VoiceTranscriptionUpdate: Sendable, Equatable {
    /// Text that may still change.
    case partial(String)
    /// Text that is finalized and ready to send.
    case final(String)
    /// Recognition failed with a user-loggable message.
    case failed(String)
}
