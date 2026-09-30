public import Foundation

/// A speech-to-text engine driving one dictation session.
///
/// Production conformances are ``SpeechAnalyzerDictationTranscriber``
/// (macOS 26+), ``SFSpeechDictationTranscriber`` (macOS 14–25), and the
/// opt-in ``CloudDictationTranscriber`` that sends the recorded audio to
/// OpenAI. Tests inject ``FixtureDictationTranscriber`` or another fake that
/// yields scripted ``DictationTranscriptionEvent`` values.
///
/// A transcriber instance runs at most one session: ``transcribe(locale:)``
/// starts audio capture plus recognition and returns the event stream;
/// ``finishTranscribing()`` stops capture, flushes any pending final
/// results into the stream, and then ends it.
public protocol SpeechTranscribing: Sendable {
    /// Starts capturing microphone audio and transcribing it.
    ///
    /// - Parameter locale: The language to transcribe.
    /// - Returns: The live event stream. It ends after
    ///   ``finishTranscribing()`` completes the flush, or throws a
    ///   ``DictationFailure`` on unrecoverable errors.
    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error>

    /// Stops capture and finalizes the in-flight hypothesis, then ends the
    /// event stream. Safe to call at any time, including before
    /// ``transcribe(locale:)``.
    func finishTranscribing() async

    /// How long ``finishTranscribing()`` may take before the controller
    /// gives up on the session. On-device engines flush in well under a
    /// second; a cloud engine uploads the clip first.
    var stopDeadline: Duration { get }
}

extension SpeechTranscribing {
    /// The on-device default.
    public var stopDeadline: Duration { .seconds(3) }
}
