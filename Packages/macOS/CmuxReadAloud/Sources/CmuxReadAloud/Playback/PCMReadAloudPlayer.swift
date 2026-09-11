import AVFoundation
import Foundation

/// Plays streamed mono 32 kHz signed 16-bit little-endian PCM through local audio output.
///
/// The coordinator owns playback sessions. At most 400 ms of decoded audio is
/// scheduled ahead, plus the current incoming chunk and one incomplete sample.
@MainActor
public final class PCMReadAloudPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 32_000, channels: 1)
    private var graphConnected = false
    private var generation: UUID?
    private var incompleteSample: UInt8?
    private var scheduledBuffers: Set<UUID> = []
    private var playbackWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    // Mutated only on MainActor; deinit reads the opaque token after actor access
    // has ceased. NotificationCenter permits removal from any thread.
    private nonisolated(unsafe) var configurationObserver: (any NSObjectProtocol)?

    /// Creates an idle player without starting audio output.
    public init() {}

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func begin(
        generation: UUID,
        onFailure: @escaping @MainActor @Sendable (ReadAloudPlaybackError) -> Void
    ) {
        stop()
        self.generation = generation
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.node.stop()
                self.engine.stop()
                self.graphConnected = false
                onFailure(.outputUnavailable)
            }
        }
    }

    func append(_ data: Data, generation: UUID) async throws {
        try checkActive(generation)
        var offset = 0
        while offset < data.count {
            while scheduledBuffers.count >= 4 {
                try await waitForPlayback(generation: generation)
            }
            try checkActive(generation)
            let availableBytes = data.count - offset + (incompleteSample == nil ? 0 : 1)
            let frameCount = min(3_200, availableBytes / 2)
            if frameCount == 0 {
                incompleteSample = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in bytes[offset] }
                return
            }
            guard let format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
                  let samples = buffer.floatChannelData?[0] else {
                throw ReadAloudPlaybackError.outputUnavailable
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            // AVAudioPlayerNode consumes Float32; decode LE explicitly, without alignment assumptions.
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var frame = 0
                if let low = incompleteSample {
                    samples[0] = sample(low: low, high: bytes[offset])
                    incompleteSample = nil
                    offset += 1
                    frame = 1
                }
                while frame < frameCount {
                    samples[frame] = sample(low: bytes[offset], high: bytes[offset + 1])
                    offset += 2
                    frame += 1
                }
            }
            try startEngine(format: format)
            let bufferID = UUID()
            scheduledBuffers.insert(bufferID)
            // AVFoundation invokes this legacy callback off-actor. Only Sendable IDs
            // and the main-actor player cross the seam; no audio objects cross it.
            let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.played(bufferID, generation: generation)
                }
            }
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: completion)
            if !node.isPlaying {
                node.play()
            }
        }
    }

    func finish(generation: UUID) async throws {
        try checkActive(generation)
        guard incompleteSample == nil else {
            throw ReadAloudPlaybackError.incompleteSample
        }
        while !scheduledBuffers.isEmpty {
            try await waitForPlayback(generation: generation)
        }
        try checkActive(generation)
    }

    func stop() {
        generation = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        incompleteSample = nil
        scheduledBuffers.removeAll(keepingCapacity: true)
        node.stop()
        engine.stop()
        resumeWaiters(throwing: CancellationError())
    }

    private func startEngine(format: AVAudioFormat) throws {
        if !graphConnected {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            graphConnected = true
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                // Do not expose system error details through the parent alert.
                throw ReadAloudPlaybackError.outputUnavailable
            }
        }
    }

    private func sample(low: UInt8, high: UInt8) -> Float {
        Float(Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))) / 32_768
    }

    private func checkActive(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func waitForPlayback(generation: UUID) async throws {
        try await withTaskCancellationHandler {
            try checkActive(generation)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                playbackWaiters[UUID()] = continuation
            }
            try checkActive(generation)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }
    }

    private func played(_ bufferID: UUID, generation: UUID) {
        guard self.generation == generation, scheduledBuffers.remove(bufferID) != nil else { return }
        resumeWaiters()
    }

    private func resumeWaiters(throwing error: (any Error)? = nil) {
        let waiters = playbackWaiters
        playbackWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters.values {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
}
