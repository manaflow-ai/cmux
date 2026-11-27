import AVFoundation
public import Foundation
import os
import Speech

/// The fallback on-device engine, built on `SFSpeechRecognizer`, for a
/// language SpeechAnalyzer has no model for (``OnDeviceDictationTranscriber``).
///
/// Audio comes from an `AVAudioEngine` input tap that appends buffers
/// directly to the current recognition request. `SFSpeechRecognizer`
/// finalizes per utterance, so when a final result arrives while the
/// session is still live the engine transparently starts the next
/// recognition cycle — the caller sees one continuous event stream.
/// `requiresOnDeviceRecognition` is always set; if the language has no
/// on-device model the session fails instead of contacting Apple servers.
public actor SFSpeechDictationTranscriber: SpeechTranscribing {
    /// The current recognition request, shared with the audio-thread tap.
    ///
    /// Lock carve-out: the `AVAudioEngine` tap is a synchronous audio-thread
    /// callback that must append buffers inline — an actor hop would add
    /// suspension points to a real-time path. The lock guards one reference
    /// with short, non-blocking critical sections.
    private final class RequestBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        // Guarded by `lock`; only touched inside withLock-style sections.
        private var request: SFSpeechAudioBufferRecognitionRequest?

        func replace(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
            lock.lock()
            defer { lock.unlock() }
            request = newRequest
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            request?.append(buffer)
        }

        func endAudio() {
            lock.lock()
            defer { lock.unlock() }
            request?.endAudio()
            request = nil
        }
    }

    private let requestBox = RequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var configurationChangeTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isFinishing = false
    private var consecutiveErrorCycles = 0
    private var recognitionCycleGeneration = 0
    /// Latest partial for the current cycle, promoted before a live retry.
    private var cyclePartial = ""
    private let retryClock: any Clock<Duration>
    private let retryDelay: Duration
    private let levelMeter: DictationAudioLevelMeter?

    /// Keeps recognizer callbacks bounded when the insertion target is slow.
    /// A dropped event fails the session rather than silently losing a final.
    private static let eventBufferCapacity = 32

    /// Creates an engine for one session.
    ///
    /// - Parameter levelMeter: Receives input levels for the dictation meter.
    public init(levelMeter: DictationAudioLevelMeter? = nil) {
        retryClock = ContinuousClock()
        retryDelay = .milliseconds(100)
        self.levelMeter = levelMeter
    }

    /// Creates an engine with caller-supplied retry timing.
    init(retryClock: any Clock<Duration>, retryDelay: Duration) {
        self.retryClock = retryClock
        self.retryDelay = retryDelay
        levelMeter = nil
    }

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.locale.identifier(.bcp47) == locale.identifier(.bcp47),
              recognizer.isAvailable else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }
        self.recognizer = recognizer

        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        self.continuation = continuation

        do {
            try startAudioEngine()
        } catch {
            self.continuation = nil
            throw DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
        beginRecognitionCycle()
        observeConfigurationChanges()
        return stream
    }

    public func finishTranscribing() async {
        // Deliberately idempotent (no isFinishing guard): a stop that races
        // transcribe() calls this again after startup completes to tear
        // down the engine the first call could not see yet.
        isFinishing = true
        retryTask?.cancel()
        retryTask = nil
        stopAudioEngine()
        // endAudio() lets the recognizer deliver its final result, which
        // ends the stream via handleRecognition; if no task is running the
        // stream ends here.
        requestBox.endAudio()
        if recognitionTask == nil {
            finishStream()
        }
    }

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let box = requestBox
        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter?.record(buffer)
            box.append(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopAudioEngine() {
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    /// Restarts the tap when the input device or its format changes
    /// (device unplugged, default input switched) instead of crashing on a
    /// stale-format tap.
    private func observeConfigurationChanges() {
        configurationChangeTask = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange
            )
            for await _ in changes {
                guard let self else { return }
                await self.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard !isFinishing, audioEngine != nil else { return }
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        do {
            try startAudioEngine()
        } catch {
            failStream(.audioCaptureFailed(error.localizedDescription))
        }
    }

    private func beginRecognitionCycle() {
        guard let recognizer, !isFinishing else { return }
        recognitionCycleGeneration += 1
        let cycleID = recognitionCycleGeneration
        cyclePartial = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        requestBox.replace(request)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognizer invokes this on an arbitrary queue; hop
            // back into the actor to touch state.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            Task { [weak self] in
                await self?.handleRecognition(
                    cycleID: cycleID,
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleRecognition(
        cycleID: Int,
        text: String?,
        isFinal: Bool,
        errorDescription: String?
    ) {
        guard cycleID == recognitionCycleGeneration else { return }
        if let text, !isFinal {
            cyclePartial = text
            yield(.partial(text))
            // Apple may deliver a last partial hypothesis together with an
            // error. Preserve the hypothesis, then apply the same terminal or
            // retry policy as an error-only callback so the cycle cannot hang.
            if errorDescription == nil {
                return
            }
        }
        if let text, isFinal {
            cyclePartial = ""
            consecutiveErrorCycles = 0
            retryTask?.cancel()
            retryTask = nil
            recognitionTask = nil
            yield(.final(text))
            if isFinishing {
                finishStream()
            } else {
                beginRecognitionCycle()
            }
            return
        }
        if let errorDescription {
            recognitionTask = nil
            if !cyclePartial.isEmpty {
                let trailingPartial = cyclePartial
                cyclePartial = ""
                yield(.final(trailingPartial))
            }
            if isFinishing {
                // Cancellation/no-speech at shutdown is expected; the
                // session already captured everything it will get.
                finishStream()
                return
            }
            // Transient recognizer errors (silence timeouts and the like)
            // restart the cycle; give up after several in a row.
            consecutiveErrorCycles += 1
            if consecutiveErrorCycles >= 3 {
                failStream(.transcriptionFailed(errorDescription))
            } else {
                scheduleRecognitionRetry(for: cycleID)
            }
        }
    }

    private func scheduleRecognitionRetry(for cycleID: Int) {
        retryTask?.cancel()
        let clock = retryClock
        let delay = retryDelay
        retryTask = Task { [weak self] in
            do {
                // wakeup-allow: one-shot 100 ms retry after a recognizer error, live sessions only, capped by consecutiveErrorCycles
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.retryDelayElapsed(for: cycleID)
        }
    }

    private func retryDelayElapsed(for cycleID: Int) {
        guard cycleID == recognitionCycleGeneration else { return }
        retryTask = nil
        guard !isFinishing else { return }
        beginRecognitionCycle()
    }

    private func yield(_ event: DictationTranscriptionEvent) {
        guard let continuation else { return }
        switch continuation.yield(event) {
        case .dropped(let dropped):
            // Partials are replaceable display state. A dropped final would lose
            // text that can never be reconstructed, so terminate the stream.
            if case .final = dropped {
                failStream(.transcriptionFailed("recognition output backlog"))
            }
        case .enqueued, .terminated:
            break
        @unknown default:
            break
        }
    }

    private func finishStream() {
        retryTask?.cancel()
        retryTask = nil
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.replace(nil)
        continuation?.finish()
        continuation = nil
    }

    private func failStream(_ failure: DictationFailure) {
        isFinishing = true
        retryTask?.cancel()
        retryTask = nil
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.replace(nil)
        continuation?.finish(throwing: failure)
        continuation = nil
    }
}
