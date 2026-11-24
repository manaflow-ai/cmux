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
    /// Hands tap buffers to one pump task in order. The tap is a real-time
    /// callback and cannot await an actor; `yield` is synchronous.
    private struct Buffer: @unchecked Sendable { let pcm: AVAudioPCMBuffer }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "dictation")
    private static let eventBufferCapacity = 32
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
        let (buffers, input) = AsyncStream<Buffer>.makeStream(bufferingPolicy: .unbounded)
        self.input = input
        pump = Task {
            for await buffer in buffers { await manager.streamAudio(buffer.pcm) }
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
            input.yield(Buffer(pcm: buffer))
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
