import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer`-backed ``DictationRecognizing`` session.
///
/// One instance per dictation attempt. Wraps an `SFSpeechAudioBufferRecognitionRequest`
/// fed by ``DictationAudioEngine``'s input tap and reports partials/final results
/// through the event stream. On-device recognition is required when the
/// recognizer supports it (privacy + offline), matching the iOS composer
/// dictation precedent; otherwise recognition falls back to Apple's server path.
public actor SpeechDictationEngine: DictationRecognizing {
    /// The recognizer for the device's current locale; `nil` when unsupported,
    /// which fails the session on start.
    private let recognizer: SFSpeechRecognizer?

    /// The off-main audio-hardware owner.
    private let audioEngine = DictationAudioEngine()

    /// The in-flight buffer request; non-nil between `start` and teardown.
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// The in-flight recognition task; cancelled on teardown.
    private var task: SFSpeechRecognitionTask?

    /// The live event continuation; finished exactly once at session end.
    private var continuation: AsyncStream<DictationRecognitionEvent>.Continuation?

    /// Whether the session has ended (guards double finish/cancel).
    private var isFinished = false

    /// Builds an engine for the device's current locale.
    public init() {
        recognizer = SFSpeechRecognizer()
    }

    public func start() -> AsyncStream<DictationRecognitionEvent> {
        // A second start on the same instance is a programming error; yield a
        // failed one-shot stream rather than trapping.
        if continuation != nil {
            finishContinuation()
            return AsyncStream { $0.yield(.failed); $0.finish() }
        }
        let stream = AsyncStream<DictationRecognitionEvent> { continuation in
            continuation.onTermination = { [weak self] _ in
                // Consumer task cancelled: hard-teardown without hopping through
                // actor methods (which would deadlock a cancelled task await).
                Task { await self?.cancel() }
            }
            self.continuation = continuation
        }
        beginRecognition()
        return stream
    }

    public func finish() {
        guard !isFinished else { return }
        // Flush the audio tail so the recognizer can produce the final result;
        // the stream ends when that final result (or the controller watchdog)
        // lands. The engine keeps running until teardown after the final result.
        request?.endAudio()
    }

    public func cancel() {
        guard !isFinished else { return }
        teardown()
    }

    /// Begins recognition: hands the blocking engine start to the off-main owner
    /// and creates the recognition task once it reports ready.
    private func beginRecognition() {
        guard let recognizer else {
            fail()
            return
        }
        guard recognizer.isAvailable else {
            fail()
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        audioEngine.start(tapBlock: Self.makeTapBlock(request: request)) { [weak self] started in
            Task { await self?.handleEngineReady(started) }
        }
    }

    /// Applies the engine owner's start result. Any failure tears the session
    /// down and reports `.failed`.
    private func handleEngineReady(_ started: Bool) {
        guard !isFinished else { return }
        guard started, let recognizer, let request else {
            fail()
            return
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { await self?.handleRecognitionResult(
                transcript: transcript,
                isFinal: isFinal,
                failed: failed
            ) }
        }
    }

    /// Applies one recognition callback. Empty transcripts are ignored so a
    /// final-with-no-text cannot wipe partials already surfaced.
    private func handleRecognitionResult(transcript: String?, isFinal: Bool, failed: Bool) {
        if let transcript, !transcript.isEmpty {
            yield(.partial(transcript))
            if isFinal {
                yield(.final(transcript))
                teardown()
            }
        }
        if failed {
            yield(.failed)
            teardown()
        }
    }

    private func fail() {
        yield(.failed)
        teardown()
    }

    private func yield(_ event: DictationRecognitionEvent) {
        continuation?.yield(event)
        if case .final = event {
            // Keep the stream open for finish(); teardown finishes it.
        }
    }

    private func teardown() {
        isFinished = true
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        audioEngine.stop()
        finishContinuation()
    }

    private func finishContinuation() {
        continuation?.finish()
        continuation = nil
    }

    /// Builds the audio-tap block. `nonisolated` + `@Sendable` so it crosses
    /// into the owner's queue and the realtime render thread; the request is
    /// captured `nonisolated(unsafe)` because `SFSpeechAudioBufferRecognitionRequest`
    /// is not `Sendable` but `append(_:)` is documented thread-safe and the weak
    /// reference never outlives the request.
    private nonisolated static func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        nonisolated(unsafe) weak let weakRequest: SFSpeechAudioBufferRecognitionRequest? = request
        return { buffer, _ in
            weakRequest?.append(buffer)
        }
    }
}
