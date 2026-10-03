import AVFoundation
import CoreMedia
public import Foundation
import os
import Speech

/// The on-device dictation engine, built on SpeechAnalyzer and SpeechTranscriber.
///
/// Model assets are managed through `AssetInventory`: the first session in
/// a given language downloads the on-device model (the session's
/// ``DictationPhase/starting`` phase), later sessions start immediately.
/// Volatile results stream as ``DictationTranscriptionEvent/partial(_:)`` and
/// finalized runs as ``DictationTranscriptionEvent/final(_:)``; recognition
/// stays on device.
public actor SpeechAnalyzerDictationTranscriber: SpeechTranscribing {
    let inputBox = AnalyzerInputBox()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var timeline = AnalyzerTimeline()
    private var convertedInputContinuation:
        AsyncThrowingStream<AnalyzerInput, any Error>.Continuation?
    private var conversionTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var configurationChangeTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var ownedReservedLocale: Locale?
    private var analyzerStarted = false
    private var isFinishing = false
    let levelMeter: DictationAudioLevelMeter?
    #if DEBUG
    var recordedInput: URL?, recordedPlayback: Task<Void, Never>? // RecordedDictationInput
    #endif

    /// Caps queued audio to about a third of a second of 4096-frame taps; dropping the
    /// oldest lets the analyzer catch up after a model stall without an unbounded recording.
    private static let inputBufferCapacity = 8

    /// The noise floor the analyzer hears before capture, longer than the
    /// span it never transcribes, in buffers about the size of a tap's.
    private static let leadInSeconds = 1.5, leadInPieces = 10

    /// Bounds callbacks when insertion stalls; a dropped event fails the session, never loses a final.
    private static let eventBufferCapacity = 32

    /// Creates an engine for one session; `levelMeter` feeds the dictation meter.
    public init(levelMeter: DictationAudioLevelMeter? = nil) { self.levelMeter = levelMeter }

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
            AsyncThrowingStream<AnalyzerRawInput, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.inputBufferCapacity)
            )
        let (inputSequence, inputContinuation) =
            AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.inputBufferCapacity + Self.leadInPieces)
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
        // Consume results before the analyzer starts: it transcribes the audio
        // queued during startup at once, and those first words must reach
        // someone.
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        outputContinuation = continuation
        let resultConsumer = SpeechAnalyzerResultConsumer(
            transcriber: transcriber,
            continuation: continuation
        )
        resultsTask = Task { await resultConsumer.run() }

        do {
            guard !isFinishing else { throw CancellationError() }
            // Load the model before capture starts; speech heard while it was
            // still loading was never transcribed.
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            guard !isFinishing else { throw CancellationError() }
            let leadIn = AVAudioPCMBuffer.noiseFloor(analyzerFormat, seconds: Self.leadInSeconds, pieces: Self.leadInPieces)
            for input in timeline.leadIn(leadIn) { inputContinuation.yield(input) }
            do {
                try startAudioEngine()
            } catch let error where !(error is CancellationError) {
                throw DictationFailure.audioCaptureFailed(error.localizedDescription)
            }
            try await analyzer.start(inputSequence: inputSequence)
            guard self.analyzer === analyzer, !isFinishing else {
                throw CancellationError()
            }
            analyzerStarted = true
            try Task.checkCancellation()
        } catch {
            await abortStartup()
            if error is CancellationError { throw CancellationError() }
            throw (error as? DictationFailure) ?? .transcriptionFailed(error.localizedDescription)
        }

        observeConfigurationChanges()
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
        #if DEBUG
        if let recordedInput { return try playRecordedInput(recordedInput) }
        #endif
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let box = inputBox
        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            meter?.record(buffer)
            box.ingest(buffer, at: time)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    /// Converts one raw tap buffer off the realtime audio callback.
    private func convertAndYield(_ input: AnalyzerRawInput) throws {
        try Task.checkCancellation()
        guard let analyzerFormat, let continuation = convertedInputContinuation else { return }
        let buffer = input.buffer
        guard buffer.frameLength > 0 else { return }
        if buffer.format == analyzerFormat {
            let result = continuation.yield(
                timeline.input(buffer, capturedAt: input.bufferStartTime)
            )
            if case .dropped = result {
                throw DictationFailure.audioCaptureFailed("converted audio backlog")
            }
            return
        }
        let inputFormat = buffer.format
        let inputSampleRate = inputFormat.sampleRate
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
        let converted = try converter.convertOne(buffer, to: analyzerFormat)
        let result = continuation.yield(
            timeline.input(converted, capturedAt: input.bufferStartTime)
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
        #if DEBUG
        recordedPlayback?.cancel()
        #endif
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    /// Undoes a startup that failed or was cancelled before the caller got
    /// the result stream.
    private func abortStartup() async {
        stopAudioEngine()
        cancelResultsTask()
        outputContinuation?.finish()
        outputContinuation = nil
        await finishInputPipeline(cancelConversion: true)
        await cancelAnalyzer()
        await releaseReservedLocale()
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
            let failure = DictationFailure.audioCaptureFailed(error.localizedDescription)
            // Publish the failure before teardown; otherwise the result
            // consumer can settle the stream successfully first.
            outputContinuation?.finish(throwing: failure)
            outputContinuation = nil
            cancelResultsTask()
            await finishInputPipeline(cancelConversion: true)
            await cancelAnalyzer()
            await releaseReservedLocale()
        }
    }
}
