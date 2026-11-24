import AVFoundation
public import CmuxNextDictation
public import Foundation
import FluidAudio
import os

/// Dictation with the Parakeet model running in this process (Labs,
/// `labs.parakeetDictation`; docs/design/voice-byo-providers.md slice 3).
///
/// Behind the same seam as On This Mac: an `AVAudioEngine` tap feeds the
/// sliding-window recognizer, and its growing confirmed and volatile text
/// becomes finals and partials through ``DictationRunningTranscript``.
/// The first start downloads the model (``ParakeetModelStore``) while the
/// session shows Starting; Esc cancels it. Nothing leaves the machine once
/// the model is on disk.
public actor ParakeetDictationTranscriber: SpeechTranscribing {
    /// One tap buffer's samples, copied so they cross to the pump task by value. The tap is a
    /// real-time callback and cannot await an actor; `yield` is synchronous.
    private struct Buffer: Sendable {
        let channels: [[Float]]
        let sampleRate: Double

        init?(_ pcm: AVAudioPCMBuffer) {
            guard let data = pcm.floatChannelData else { return nil }
            let frames = Int(pcm.frameLength)
            channels = (0..<Int(pcm.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
            sampleRate = pcm.format.sampleRate
        }

        /// The samples as a buffer again, on the pump's side.
        var pcm: AVAudioPCMBuffer? {
            let frames = channels.first?.count ?? 0
            guard frames > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = pcm.floatChannelData else { return nil }
            pcm.frameLength = AVAudioFrameCount(frames)
            for (index, samples) in channels.enumerated() {
                samples.withUnsafeBufferPointer { if let base = $0.baseAddress { data[index].update(from: base, count: frames) } }
            }
            return pcm
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "dictation")
    private static let eventBufferCapacity = 32
    /// Tap buffers waiting for the recognizer: 4096 frames each, so 128 is several seconds of
    /// speech; past that the oldest audio drops rather than memory growing.
    private static let audioBufferCapacity = 128
    private let store: ParakeetModelStore
    private let levelMeter: DictationAudioLevelMeter?
    private var manager: SlidingWindowAsrManager?
    private var audioEngine: AVAudioEngine?
    private var input: AsyncStream<Buffer>.Continuation?
    private var pump: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var running = DictationRunningTranscript()
    private var isFinishing = false

    public init(store: ParakeetModelStore, levelMeter: DictationAudioLevelMeter?) {
        self.store = store
        self.levelMeter = levelMeter
    }

    public func transcribe(locale: Locale) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        // The multilingual model detects the language itself; `locale` is not needed.
        let models: AsrModels
        do {
            models = try await store.models()
        } catch {
            if isFinishing || error is CancellationError { throw CancellationError() }
            throw DictationFailure.modelDownloadFailed(error.localizedDescription)
        }
        guard !isFinishing else { throw CancellationError() }

        let manager = SlidingWindowAsrManager(config: .default)
        do {
            try await manager.loadModels(models)
            try await manager.startStreaming(source: .microphone)
        } catch {
            throw DictationFailure.transcriptionFailed(error.localizedDescription)
        }
        // A stop during the loads above found nothing to stop yet.
        guard !isFinishing else {
            await manager.cancel()
            throw CancellationError()
        }
        self.manager = manager
        let updates = await manager.transcriptionUpdates

        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferCapacity)
        )
        self.continuation = continuation
        let (buffers, input) = AsyncStream<Buffer>.makeStream(bufferingPolicy: .bufferingNewest(Self.audioBufferCapacity))
        self.input = input
        pump = Task {
            for await buffer in buffers {
                guard let pcm = buffer.pcm else { continue }
                await manager.streamAudio(pcm)
            }
        }
        reader = Task { [weak self] in
            for await _ in updates {
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                await self?.emit(confirmed: confirmed, volatile: volatile)
            }
        }
        do {
            try startAudioEngine(input)
        } catch {
            await tearDown()
            throw DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
        Self.logger.info("dictation engine: Parakeet")
        return stream
    }

    public func finishTranscribing() async {
        guard !isFinishing else { return }
        isFinishing = true
        stopAudioEngine()
        input?.finish()
        await pump?.value
        guard let manager else { return }
        do {
            let text = try await manager.finish()
            reader?.cancel()
            continuation?.yield(running.finish(text: text))
            continuation?.finish()
        } catch {
            reader?.cancel()
            continuation?.finish(throwing: DictationFailure.transcriptionFailed(error.localizedDescription))
        }
        continuation = nil
        await manager.cancel()
        self.manager = nil
    }

    private func emit(confirmed: String, volatile: String) {
        guard !isFinishing else { return }
        for event in running.update(confirmed: confirmed, volatile: volatile) {
            continuation?.yield(event)
        }
    }

    private func startAudioEngine(_ input: AsyncStream<Buffer>.Continuation) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let meter = levelMeter
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter?.record(buffer)
            if let copy = Buffer(buffer) { input.yield(copy) }
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopAudioEngine() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
    }

    private func tearDown() async {
        stopAudioEngine()
        input?.finish()
        pump?.cancel()
        reader?.cancel()
        continuation = nil
        await manager?.cancel()
        manager = nil
    }
}
