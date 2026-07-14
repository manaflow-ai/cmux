import AVFoundation
public import Foundation
import os
import Speech

/// On-device dictation engine for macOS 14–25 built on `SFSpeechRecognizer`.
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
    private var isFinishing = false
    private var consecutiveErrorCycles = 0

    /// Creates an engine for one session.
    public init() {}

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }
        self.recognizer = recognizer

        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
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
        guard !isFinishing else { return }
        isFinishing = true
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
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
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
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleRecognition(text: String?, isFinal: Bool, errorDescription: String?) {
        if let text, !isFinal {
            consecutiveErrorCycles = 0
            continuation?.yield(.partial(text))
            return
        }
        if let text, isFinal {
            consecutiveErrorCycles = 0
            recognitionTask = nil
            continuation?.yield(.final(text))
            if isFinishing {
                finishStream()
            } else {
                beginRecognitionCycle()
            }
            return
        }
        if errorDescription != nil {
            recognitionTask = nil
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
                failStream(.transcriptionFailed(errorDescription ?? "recognition failed"))
            } else {
                beginRecognitionCycle()
            }
        }
    }

    private func finishStream() {
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.replace(nil)
        continuation?.finish()
        continuation = nil
    }

    private func failStream(_ failure: DictationFailure) {
        isFinishing = true
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestBox.replace(nil)
        continuation?.finish(throwing: failure)
        continuation = nil
    }
}
