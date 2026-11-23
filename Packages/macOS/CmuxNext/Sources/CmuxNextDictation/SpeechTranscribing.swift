public import Foundation

/// A speech-to-text engine driving one dictation session.
///
/// ``OnDeviceDictationTranscriber`` is the production engine (SpeechAnalyzer,
/// falling back to `SFSpeechRecognizer` on device). A cloud engine (a
/// transcription API with the user's own key) would be another conformance.
/// Tests yield scripted ``DictationTranscriptionEvent`` values.
///
/// An instance runs at most one session: ``transcribe(locale:)`` starts
/// capture and recognition and returns the event stream;
/// ``finishTranscribing()`` stops capture, flushes pending final results into
/// the stream, and ends it.
public protocol SpeechTranscribing: Sendable {
    /// Starts capturing microphone audio and transcribing it.
    ///
    /// - Returns: The live event stream. It ends after
    ///   ``finishTranscribing()`` completes the flush, or throws a
    ///   ``DictationFailure``.
    func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error>

    /// Stops capture, releases the microphone, finalizes the in-flight
    /// hypothesis, then ends the event stream. Safe to call at any time,
    /// including before ``transcribe(locale:)``.
    func finishTranscribing() async

    /// How long ``DictationSession`` waits in finalizing after stop before it
    /// ends the session itself; `nil` uses the session's own deadline (3 s).
    /// ``RecordedDictationTranscriber`` waits for its provider to answer.
    var finalizingDeadline: Duration? { get }

    /// Ends the session without a result: Esc, or a stop before capture
    /// started. An engine that sends audio somewhere on finish (a provider)
    /// must not send it here. The default is ``finishTranscribing()``.
    func cancelTranscribing() async
}

extension SpeechTranscribing {
    public var finalizingDeadline: Duration? { nil }

    public func cancelTranscribing() async {
        await finishTranscribing()
    }
}
