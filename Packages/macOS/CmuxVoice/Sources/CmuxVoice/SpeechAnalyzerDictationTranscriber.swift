import AVFoundation
public import Foundation
import os
import Speech

/// On-device dictation engine for macOS 26+ built on the
/// SpeechAnalyzer / SpeechTranscriber API family.
///
/// Model assets are managed through `AssetInventory`: the first session in
/// a given language downloads the on-device model (surfaced to the user as
/// the ``DictationPhase/preparing`` phase), later sessions start
/// immediately. Volatile results stream as ``DictationTranscriptionEvent/partial(_:)``
/// and finalized runs as ``DictationTranscriptionEvent/final(_:)``.
/// Recognition never leaves the machine.
@available(macOS 26.0, *)
public actor SpeechAnalyzerDictationTranscriber: SpeechTranscribing {
    /// The audio converter feeding the analyzer, shared with the
    /// audio-thread tap.
    ///
    /// Lock carve-out: the `AVAudioEngine` tap is a synchronous audio-thread
    /// callback; conversion and yield must happen inline without actor hops.
    private final class InputBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        // All three guarded by `lock`.
        private var converter: AVAudioConverter?
        private var analyzerFormat: AVAudioFormat?
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?

        func configure(
            analyzerFormat: AVAudioFormat,
            continuation: AsyncStream<AnalyzerInput>.Continuation
        ) {
            lock.lock()
            defer { lock.unlock() }
            self.analyzerFormat = analyzerFormat
            self.continuation = continuation
            converter = nil
        }

        /// Drops the cached converter so the next buffer rebuilds it against
        /// the current input format (device/route changes).
        func resetConverter() {
            lock.lock()
            defer { lock.unlock() }
            converter = nil
        }

        func ingest(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard let analyzerFormat, let continuation else { return }
            if buffer.format == analyzerFormat {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
                converter?.primeMethod = .none
            }
            guard let converter else { return }
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: analyzerFormat,
                frameCapacity: max(capacity, 1)
            ) else { return }
            let feed = SingleBufferFeed(buffer)
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, outStatus in
                guard let next = feed.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            guard conversionError == nil, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            continuation?.finish()
            continuation = nil
            converter = nil
            analyzerFormat = nil
        }
    }

    /// Hands one buffer to `AVAudioConverter`'s input block.
    ///
    /// The block runs synchronously inside `convert(to:error:)` on the
    /// calling (audio) thread, so the buffer never actually crosses threads
    /// despite the block's `@Sendable` annotation.
    private final class SingleBufferFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    private let inputBox = InputBox()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var resultsTask: Task<Void, Never>?
    private var configurationChangeTask: Task<Void, Never>?
    private var isFinishing = false

    /// Creates an engine for one session.
    public init() {}

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        do {
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            throw DictationFailure.modelDownloadFailed(error.localizedDescription)
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBox.configure(analyzerFormat: analyzerFormat, continuation: inputContinuation)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        do {
            try startAudioEngine()
        } catch {
            inputBox.finish()
            throw DictationFailure.audioCaptureFailed(error.localizedDescription)
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            stopAudioEngine()
            inputBox.finish()
            throw DictationFailure.transcriptionFailed(error.localizedDescription)
        }

        observeConfigurationChanges()

        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    continuation.yield(result.isFinal ? .final(text) : .partial(text))
                }
                continuation.finish()
            } catch {
                continuation.finish(
                    throwing: DictationFailure.transcriptionFailed(error.localizedDescription)
                )
            }
        }
        return stream
    }

    public func finishTranscribing() async {
        guard !isFinishing else { return }
        isFinishing = true
        stopAudioEngine()
        inputBox.finish()
        // Finalizes the trailing volatile hypothesis; the results sequence
        // then ends, which ends the caller's event stream.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        transcriber = nil
    }

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let box = inputBox
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            box.ingest(buffer)
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

    /// Reinstalls the tap when the input device or its format changes
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
        guard !isFinishing, let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        inputBox.resetConverter()
        try? startAudioEngine()
    }
}
