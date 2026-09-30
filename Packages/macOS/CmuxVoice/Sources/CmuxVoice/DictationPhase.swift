import Foundation

/// The lifecycle state of a voice-dictation session.
///
/// ``DictationController`` owns exactly one phase at a time and moves
/// through them in order for a successful session:
/// `idle → requestingAuthorization → preparing → listening → stopping → idle`.
/// Any step can divert to ``failed(_:)``, which is a resting state like
/// ``idle`` — toggling dictation again starts a fresh session.
public enum DictationPhase: Equatable, Sendable {
    /// No session is running.
    case idle

    /// Checking or requesting microphone / speech-recognition access.
    case requestingAuthorization

    /// Authorization granted; the transcriber is starting up (this covers
    /// on-device model download on first use of a language).
    case preparing

    /// The microphone is live and speech is being transcribed.
    case listening

    /// The user asked to stop; the engine is flushing its final results.
    case stopping

    /// The last session ended with an error. Resting state; a new toggle
    /// retries from scratch.
    case failed(DictationFailure)
}
