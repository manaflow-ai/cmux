import Foundation

/// One event from a running dictation recognition session.
public enum DictationRecognitionEvent: Sendable {
    /// Interim transcript; replaces any previous partial.
    case partial(String)
    /// Final transcript for the session. No events follow.
    case final(String)
    /// Recognition failed; the session is over.
    case failed
}

/// One startable speech-recognition session.
///
/// A conformer is created per dictation attempt (via the controller's injected
/// factory) and consumed exactly once: `start()` hands back the event stream,
/// and either `finish()` (graceful: flush audio tail, await the final result)
/// or `cancel()` (hard teardown) ends it. Idempotent finish/cancel.
public protocol DictationRecognizing: Sendable {
    /// Begins capturing microphone audio and recognizing speech.
    ///
    /// - Returns: A stream of recognition events. The stream finishes when the
    ///   session ends by any path (final result, failure, finish, cancel).
    func start() async -> AsyncStream<DictationRecognitionEvent>

    /// Gracefully ends the session: flushes buffered audio so the recognizer
    /// can produce the final transcript, then ends the stream.
    func finish() async

    /// Hard-cancels the session immediately, discarding any unrecognized tail.
    func cancel() async
}
