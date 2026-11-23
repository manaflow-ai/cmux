public import Foundation

/// One session's live connection to the person's streaming provider (acpmux's
/// `_acpmux/voice/stream.*`, crate cmux-voice): the audio goes up as it is
/// heard and the words come back while the person speaks. acpmux's session
/// reducer has already turned the provider's events into ``events``: a
/// partial replaces the words so far, a final commits a stretch.
public protocol DictationLiveStream: Sendable {
    /// The words, in order. Ends when the session ends: after ``stop()``
    /// answers, a ``cancel()``, or a failure.
    var events: AsyncStream<DictationTranscriptionEvent> { get }

    /// 16 kHz mono PCM16 samples, in speaking order. Never blocks: the
    /// microphone's tap calls it.
    func send(_ samples: [Int16])

    /// No more audio: waits for the last words (their events come first).
    /// Throws ``DictationFailure/providerFailed(code:detail:)``.
    func stop() async throws

    /// Ends the session at once; nothing more is shown.
    func cancel() async
}

/// Opens a live stream for one session in its language; nil when the
/// person's provider does not stream (the session records and transcribes on
/// stop). Throws ``DictationFailure/providerFailed(code:detail:)``.
public typealias OpenDictationStream = @Sendable (Locale) async throws -> (any DictationLiveStream)?
