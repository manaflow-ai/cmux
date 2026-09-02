import AVFoundation
import CoreMedia
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
    /// Raw audio-tap payload. `AVAudioNodeTapBlock` documents that callbacks
    /// receive copies of node output; retaining that framework-supplied copy
    /// here extends its lifetime until the single conversion worker consumes
    /// it. AnalyzerInput construction happens on that worker.
    private struct RawAudioInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let sampleTime: AVAudioFramePosition?
        let sampleRate: Double?

        var bufferStartTime: CMTime? {
            guard let sampleTime, let sampleRate, sampleRate > 0 else { return nil }
            let roundedRate = min(sampleRate.rounded(), Double(Int32.max))
            return CMTime(value: sampleTime, timescale: CMTimeScale(roundedRate))
        }
    }

    /// The bounded handoff from the audio-thread tap to the actor.
    ///
    /// Lock carve-out: the AVAudioEngine tap is a synchronous audio-thread
    /// callback. It only snapshots the continuation and enqueues the tap's
    /// output copy; format conversion and AnalyzerInput allocation happen on
    /// the actor's worker task.
    private final class InputBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        // The continuation is guarded by lock.
        private var continuation:
            AsyncThrowingStream<RawAudioInput, any Error>.Continuation?

        func configure(
            continuation: AsyncThrowingStream<RawAudioInput, any Error>.Continuation
        ) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            guard let continuation else { return }
            let result = continuation.yield(
                RawAudioInput(
                    buffer: buffer,
                    sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                    sampleRate: time.isSampleTimeValid ? time.sampleRate : nil
                )
            )
            if case .dropped = result {
                continuation.finish(
                    throwing: DictationFailure.audioCaptureFailed(
                        "audio input backlog"
                    )
                )
            }
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            continuation?.finish()
            continuation = nil
        }
    }

    /// Hands one buffer to `AVAudioConverter`'s input block.
    ///
    /// The block runs synchronously inside convert(to:error:) on the
    /// conversion worker, so the buffer never actually crosses threads
    /// despite the @Sendable annotation.
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
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var convertedInputContinuation:
        AsyncThrowingStream<AnalyzerInput, any Error>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var configurationChangeTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var ownedReservedLocale: Locale?
    private var analyzerStarted = false
    private var isFinishing = false

    /// Caps queued audio to roughly a third of a second at the 4096-frame
    /// tap size. Dropping the oldest buffer lets the analyzer catch up after
    /// a temporary model stall without retaining an unbounded recording.
    private static let inputBufferCapacity = 8

    /// Keeps transcription callbacks bounded when insertion briefly stalls.
    /// A dropped event fails the session rather than silently losing a final.
    private static let eventBufferCapacity = 32

    /// Creates an engine for one session.
    public init() {}

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        try Task.checkCancellation()
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        try Task.checkCancellation()
        guard let supportedLocale else {
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            // Apple's volatileResults contract emits tentative results for an
            // audio range in addition to its finalized result.
            reportingOptions: [.volatileResults],
            // Preserve per-run audio ranges so finalization metadata can
            // commit an unchanged volatile result without a second callback.
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber
        do {
            // AssetInventory returns false when another app-owned reservation
            // already covers this locale. Only release a reservation acquired
            // by this session; releasing a pre-existing one would invalidate
            // its actual owner.
            let acquiredReservation = try await AssetInventory.reserve(locale: supportedLocale)
            if acquiredReservation {
                ownedReservedLocale = supportedLocale
            }
            try Task.checkCancellation()
            if let installationRequest = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await installationRequest.downloadAndInstall()
            }
        } catch is CancellationError {
            await releaseReservedLocale()
            throw CancellationError()
        } catch {
            await releaseReservedLocale()
            throw DictationFailure.modelDownloadFailed(error.localizedDescription)
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            await releaseReservedLocale()
            throw DictationFailure.onDeviceRecognitionUnavailable(localeIdentifier: locale.identifier)
        }
        do {
            try Task.checkCancellation()
        } catch {
            await releaseReservedLocale()
            throw error
        }
        guard !isFinishing else {
            await releaseReservedLocale()
            throw CancellationError()
        }

        let (rawInputSequence, rawInputContinuation) =
            AsyncThrowingStream<RawAudioInput, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.inputBufferCapacity)
            )
        let (inputSequence, inputContinuation) =
            AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.inputBufferCapacity)
            )
        inputBox.configure(continuation: rawInputContinuation)
        self.analyzerFormat = analyzerFormat
        self.convertedInputContinuation = inputContinuation
        conversionTask = Task { [weak self] in
            do {
                for try await input in rawInputSequence {
                    guard let self else { return }
                    try await self.convertAndYield(input)
                }
                await self?.finishConvertedInput()
            } catch {
                await self?.handleConversionFailure(error)
            }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard !isFinishing else {
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw CancellationError()
        }
        do {
            try startAudioEngine()
        } catch is CancellationError {
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw CancellationError()
        } catch {
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw DictationFailure.audioCaptureFailed(error.localizedDescription)
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            guard self.analyzer === analyzer, !isFinishing else {
                throw CancellationError()
            }
            analyzerStarted = true
            try Task.checkCancellation()
        } catch is CancellationError {
            stopAudioEngine()
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw CancellationError()
        } catch let failure as DictationFailure {
            stopAudioEngine()
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw failure
        } catch {
            stopAudioEngine()
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
            throw DictationFailure.transcriptionFailed(error.localizedDescription)
        }

        observeConfigurationChanges()

        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        outputContinuation = continuation
        let resultConsumer = SpeechAnalyzerResultConsumer(
            transcriber: transcriber,
            continuation: continuation
        )
        resultsTask = Task { await resultConsumer.run() }
        return stream
    }

    public func finishTranscribing() async {
        // Deliberately idempotent (no isFinishing guard): a stop that races
        // transcribe() calls this again after startup completes to tear
        // down the engine the first call could not see yet.
        isFinishing = true
        let analyzer = self.analyzer
        let shouldFinalize = analyzerStarted
        self.analyzer = nil
        analyzerStarted = false
        stopAudioEngine()
        await finishInputPipeline(cancelConversion: false)
        if let analyzer {
            do {
                if shouldFinalize {
                    // Finalizes the trailing volatile hypothesis; the results
                    // sequence then ends, which ends the caller's event stream.
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } else {
                    // finalizeAndFinishThroughEndOfInput() waits for a future
                    // input sequence when start() never succeeded. Immediate
                    // cancellation is the only bounded cleanup in that state.
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                // The results sequence may never end after a failed finalize.
                // End it directly, but preserve the failure so the controller
                // cannot settle the session as a successful stop after losing the
                // trailing hypothesis.
                let failure = (error as? DictationFailure)
                    ?? .transcriptionFailed(error.localizedDescription)
                outputContinuation?.finish(throwing: failure)
                cancelResultsTask()
                await analyzer.cancelAndFinishNow()
            }
        }
        transcriber = nil
        outputContinuation = nil
        await releaseReservedLocale()
    }

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let box = inputBox
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            box.ingest(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    /// Converts one raw tap buffer off the realtime audio callback.
    private func convertAndYield(_ input: RawAudioInput) throws {
        try Task.checkCancellation()
        guard let analyzerFormat, let continuation = convertedInputContinuation else { return }
        let buffer = input.buffer
        guard buffer.frameLength > 0 else { return }
        if buffer.format == analyzerFormat {
            let result = continuation.yield(
                AnalyzerInput(buffer: buffer, bufferStartTime: input.bufferStartTime)
            )
            if case .dropped = result {
                throw DictationFailure.audioCaptureFailed("converted audio backlog")
            }
            return
        }
        let inputFormat = buffer.format
        let inputSampleRate = inputFormat.sampleRate
        let inputFrameLength = buffer.frameLength
        guard inputSampleRate.isFinite, inputSampleRate > 0 else {
            throw DictationFailure.audioCaptureFailed("invalid audio input sample rate")
        }
        if converter == nil || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
            converter?.primeMethod = .none
        }
        guard let converter else {
            throw DictationFailure.audioCaptureFailed("audio format conversion unavailable")
        }
        let ratio = analyzerFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(
            (Double(inputFrameLength) * ratio).rounded(.up) + 16
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: analyzerFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            throw DictationFailure.audioCaptureFailed("audio conversion buffer unavailable")
        }
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
        if let conversionError {
            throw DictationFailure.audioCaptureFailed(conversionError.localizedDescription)
        }
        guard converted.frameLength > 0 else {
            throw DictationFailure.audioCaptureFailed("audio conversion produced no frames")
        }
        let result = continuation.yield(
            AnalyzerInput(buffer: converted, bufferStartTime: input.bufferStartTime)
        )
        if case .dropped = result {
            throw DictationFailure.audioCaptureFailed("converted audio backlog")
        }
    }

    private func finishConvertedInput() {
        convertedInputContinuation?.finish()
        convertedInputContinuation = nil
        converter = nil
        analyzerFormat = nil
    }

    private func finishConvertedInput(throwing error: any Error) {
        convertedInputContinuation?.finish(throwing: error)
        convertedInputContinuation = nil
        inputBox.finish()
        converter = nil
        analyzerFormat = nil
    }

    /// Surfaces conversion failures through the public result stream; the
    /// controller owns the subsequent analyzer teardown and finish task.
    private func handleConversionFailure(_ error: any Error) {
        finishConvertedInput(throwing: error)
        guard !isFinishing else { return }
        isFinishing = true
        stopAudioEngine()
        let failure = (error as? DictationFailure)
            ?? .audioCaptureFailed(error.localizedDescription)
        outputContinuation?.finish(throwing: failure)
        cancelResultsTask()
    }

    private func releaseReservedLocale() async {
        guard let reservedLocale = ownedReservedLocale else { return }
        ownedReservedLocale = nil
        _ = await AssetInventory.release(reservedLocale: reservedLocale)
    }

    /// Cancels analysis without waiting for an input sequence to exist.
    private func cancelAnalyzer() async {
        let analyzer = self.analyzer
        self.analyzer = nil
        analyzerStarted = false
        transcriber = nil
        await analyzer?.cancelAndFinishNow()
    }

    private func finishInputPipeline(cancelConversion: Bool) async {
        inputBox.finish()
        if cancelConversion {
            conversionTask?.cancel()
        }
        await conversionTask?.value
        conversionTask = nil
        finishConvertedInput()
    }

    private func stopAudioEngine() {
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    /// Cancels the result consumer when the analyzer cannot finish normally.
    private func cancelResultsTask() {
        resultsTask?.cancel()
        resultsTask = nil
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

    private func handleConfigurationChange() async {
        guard !isFinishing, let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        converter = nil
        do {
            try startAudioEngine()
        } catch {
            // No usable input device after the change: fail the session
            // instead of listening to silence forever.
            isFinishing = true
            await finishInputPipeline(cancelConversion: true)
            outputContinuation?.finish(
                throwing: DictationFailure.audioCaptureFailed(error.localizedDescription)
            )
            cancelResultsTask()
            outputContinuation = nil
            await cancelAnalyzer()
            await releaseReservedLocale()
        }
    }
}
