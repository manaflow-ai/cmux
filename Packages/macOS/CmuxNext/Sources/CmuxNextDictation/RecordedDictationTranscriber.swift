import AVFoundation
public import Foundation

/// An engine that records the session and has the person's own dictation
/// provider (`agentPane.dictationEngine`) transcribe it on stop: OpenAI,
/// Groq, a local Whisper or Parakeet server, whisper.cpp, any OpenAI-style
/// endpoint. Leo, 2026-11-22: "people should be able to add their own api
/// keys/whatever and toggle that voice mode and whatever to link up to
/// their provider of choice. just like our mic thing."
///
/// While listening it feeds the level meter (and through it the session's
/// own recording) and its own 16 kHz WAV, and yields nothing. On
/// ``finishTranscribing()`` it stops capture, closes the WAV, hands it to the
/// injected transcription (the app's: acpmux's `_acpmux/voice/transcribe`),
/// yields the text as one final, and ends the stream. A failure ends the
/// stream with a ``DictationFailure``. ``cancelTranscribing()`` sends
/// nothing. Its WAV is removed on every path.
public actor RecordedDictationTranscriber: SpeechTranscribing {
    /// Turns one recording into text: its bytes (``DictationAudio/data``) or,
    /// for a long one, its file (``DictationAudio/file``), in the session's
    /// language. Throws ``DictationFailure/providerFailed(code:detail:)``.
    public typealias Transcribe = @Sendable (DictationAudio, Locale) async throws -> String

    private enum Stage {
        /// Made, not started.
        case ready
        /// Opening the microphone.
        case starting
        /// Recording.
        case capturing
        /// Stopped; the provider has the recording.
        case finishing
        /// Over: the stream ended or was never handed out.
        case ended
    }

    /// The provider has about a minute (acpmux allows 60 s for the whole
    /// request), plus the file's close and the socket's round trip.
    public static let providerDeadline: Duration = .seconds(65)

    private let levelMeter: DictationAudioLevelMeter?
    private let transcribeAudio: Transcribe
    private let capture: any DictationAudioCapturing
    private let recording: DictationAudioRecording
    private let deadline: Duration
    private var stage = Stage.ready
    private var locale = Locale.current
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    /// The recording on its way to the provider; a cancel cancels it.
    private var sending: Task<Void, Never>?

    /// - Parameters:
    ///   - levelMeter: Receives input levels for the dictation meter.
    ///   - transcribe: Sends a recording to the provider.
    ///   - capture: The microphone; tests script it.
    ///   - recordingFolder: A fresh folder for the WAV; nil: one under this
    ///     user's temporary folder.
    ///   - finalizingDeadline: How long the session waits for the provider
    ///     after stop.
    public init(
        levelMeter: DictationAudioLevelMeter?,
        transcribe: @escaping Transcribe,
        capture: any DictationAudioCapturing = MicrophoneDictationCapture(),
        recordingFolder: URL? = nil,
        finalizingDeadline: Duration = RecordedDictationTranscriber.providerDeadline
    ) {
        self.levelMeter = levelMeter
        transcribeAudio = transcribe
        self.capture = capture
        recording = DictationAudioRecording(folder: recordingFolder)
        deadline = finalizingDeadline
    }

    public nonisolated var finalizingDeadline: Duration? { deadline }

    public func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        // One session per engine; a finish before the start ends it unstarted.
        guard stage == .ready else { throw CancellationError() }
        stage = .starting
        self.locale = locale
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        let meter = levelMeter
        let recording = recording
        do {
            try await capture.start(
                onBuffer: { buffer in
                    meter?.record(buffer)
                    recording.record(buffer)
                },
                onFailure: { [weak self] failure in
                    await self?.captureFailed(failure)
                }
            )
        } catch {
            stage = .ended
            recording.discard()
            throw error as? DictationFailure ?? DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
        guard stage == .starting else {
            // A finish or cancel arrived while the microphone opened.
            await capture.stop()
            recording.discard()
            continuation.finish()
            throw CancellationError()
        }
        stage = .capturing
        self.continuation = continuation
        return stream
    }

    public func finishTranscribing() async {
        switch stage {
        case .ready, .starting:
            // Nothing recorded yet: transcribe() sees this and stops.
            stage = .ended
        case .capturing:
            stage = .finishing
            await capture.stop()
            guard stage == .finishing else { return }
            // task-owner: stored in sending; cancelTranscribing() cancels it, and it ends with the provider's answer
            let sending = Task { await self.deliver() }
            self.sending = sending
            await sending.value
        case .finishing, .ended:
            // Idempotent: the session finishes the engine again when its stream ends.
            break
        }
    }

    public func cancelTranscribing() async {
        let previous = stage
        stage = .ended
        sending?.cancel()
        sending = nil
        continuation?.finish()
        continuation = nil
        if previous == .capturing {
            await capture.stop()
        }
        recording.discard()
    }

    /// Closes the WAV and has the provider transcribe it.
    private func deliver() async {
        let audio = await recording.finish()
        // The bytes are in hand, or the provider has read the file by the time it answers.
        defer { recording.discard() }
        guard stage == .finishing else { return }
        guard let audio else {
            // Nothing heard ends with no text; audio that was left out says why.
            end(recording.omission.map { DictationFailure.audioCaptureFailed($0.rawValue) })
            return
        }
        do {
            let text = try await transcribeAudio(audio, locale)
            guard stage == .finishing, !Task.isCancelled else { return }
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty {
                continuation?.yield(.final(words))
            }
            end(nil)
        } catch {
            guard stage == .finishing, !Task.isCancelled else { return }
            let failure = error as? DictationFailure ?? DictationFailure.transcriptionFailed(String(describing: error))
            end(failure)
        }
    }

    /// The microphone went away mid-session and could not be reopened.
    private func captureFailed(_ failure: DictationFailure) async {
        guard stage == .capturing else { return }
        stage = .ended
        continuation?.finish(throwing: failure)
        continuation = nil
        await capture.stop()
        recording.discard()
    }

    private func end(_ failure: DictationFailure?) {
        stage = .ended
        sending = nil
        if let failure {
            continuation?.finish(throwing: failure)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }
}
