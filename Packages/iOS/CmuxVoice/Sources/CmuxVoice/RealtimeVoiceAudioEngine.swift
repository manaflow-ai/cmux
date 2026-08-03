#if os(iOS)
@preconcurrency public import AVFoundation
public import Foundation

/// Full-duplex audio owner for GPT Realtime Voice Mode.
///
/// Audio hardware calls and `AVAudioEngine` mutation run on one dedicated serial
/// queue because activation and engine startup are synchronous, blocking APIs.
/// The queue is an AVFoundation lifecycle carve-out, not a general state lock.
/// Every mutable property is accessed only on `queue`; the render callback uses
/// only the immutable converter and stream continuation captured at tap install.
public final class RealtimeVoiceAudioEngine: RealtimeVoiceAudioIO, @unchecked Sendable {
    private static let sampleRate: Double = 24_000
    private static let bytesPerFrame = MemoryLayout<Int16>.size

    private let queue = DispatchQueue(label: "com.cmux.realtime-voice-audio")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerAttached = false
    private var tapInstalled = false
    private var isActive = false
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private var playbackItemID: String?
    private var fullyPlayedFrames: AVAudioFramePosition = 0

    /// Creates an idle full-duplex audio engine.
    public init() {}

    /// Start full-duplex capture and playback without blocking the caller's actor.
    public func start() async throws -> AsyncStream<Data> {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if isActive {
                        teardownLocked()
                    }
                    let pair = AsyncStream.makeStream(
                        of: Data.self,
                        bufferingPolicy: .bufferingNewest(64)
                    )
                    inputContinuation = pair.continuation

                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(
                        .playAndRecord,
                        mode: .voiceChat,
                        options: [.defaultToSpeaker, .allowBluetoothHFP]
                    )
                    try audioSession.setPreferredSampleRate(Self.sampleRate)
                    try audioSession.setPreferredIOBufferDuration(0.02)
                    try audioSession.setActive(true)
                    isActive = true

                    let playbackFormat = try Self.pcmFormat()
                    if !playerAttached {
                        engine.attach(playerNode)
                        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
                        playerAttached = true
                    }

                    let inputNode = engine.inputNode
                    try? inputNode.setVoiceProcessingEnabled(true)
                    let inputFormat = inputNode.outputFormat(forBus: 0)
                    guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
                          let converter = AVAudioConverter(from: inputFormat, to: playbackFormat) else {
                        throw RealtimeVoiceAudioEngineError.invalidInputFormat
                    }
                    nonisolated(unsafe) let capturedConverter = converter
                    let capturedContinuation = pair.continuation
                    inputNode.installTap(
                        onBus: 0,
                        bufferSize: 960,
                        format: inputFormat
                    ) { buffer, _ in
                        Self.convertAndYield(
                            buffer,
                            converter: capturedConverter,
                            continuation: capturedContinuation
                        )
                    }
                    tapInstalled = true
                    engine.prepare()
                    try engine.start()
                    continuation.resume(returning: pair.stream)
                } catch {
                    teardownLocked()
                    continuation.resume(throwing: RealtimeVoiceAudioEngineError.startFailed)
                }
            }
        }
    }

    /// Stop capture, playback, and the shared audio session.
    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                teardownLocked()
                continuation.resume()
            }
        }
    }

    /// Queue one 24 kHz mono PCM16 assistant audio chunk.
    public func enqueuePlayback(_ data: Data, itemID: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                enqueuePlaybackLocked(data, itemID: itemID)
                continuation.resume()
            }
        }
    }

    /// Stop assistant playback and return the fully played duration.
    public func interruptPlayback() async -> RealtimeVoicePlaybackProgress? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let progress = playbackProgressLocked()
                playerNode.stop()
                playbackItemID = nil
                fullyPlayedFrames = 0
                continuation.resume(returning: progress)
            }
        }
    }

    private static func pcmFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RealtimeVoiceAudioEngineError.invalidInputFormat
        }
        return format
    }

    private static func convertAndYield(
        _ input: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        continuation: AsyncStream<Data>.Continuation
    ) {
        let ratio = sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity
        ) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error,
              conversionError == nil,
              output.frameLength > 0,
              let channel = output.int16ChannelData?[0] else { return }
        let byteCount = Int(output.frameLength) * bytesPerFrame
        continuation.yield(Data(bytes: channel, count: byteCount))
    }

    private func enqueuePlaybackLocked(_ data: Data, itemID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive,
              !data.isEmpty,
              data.count.isMultiple(of: Self.bytesPerFrame),
              let format = try? Self.pcmFormat() else { return }
        if playbackItemID != itemID {
            playerNode.stop()
            playbackItemID = itemID
            fullyPlayedFrames = 0
        }
        let frameCount = AVAudioFrameCount(data.count / Self.bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let destination = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            destination.update(from: source.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
        }
        playerNode.scheduleBuffer(
            buffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.playbackItemID == itemID else { return }
                self.fullyPlayedFrames += AVAudioFramePosition(frameCount)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func playbackProgressLocked() -> RealtimeVoicePlaybackProgress? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let playbackItemID else { return nil }
        let milliseconds = Int(
            (Double(fullyPlayedFrames) / Self.sampleRate * 1_000).rounded(.down)
        )
        return RealtimeVoicePlaybackProgress(
            itemID: playbackItemID,
            audioEndMilliseconds: max(0, milliseconds)
        )
    }

    private func teardownLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        inputContinuation?.finish()
        inputContinuation = nil
        playerNode.stop()
        playbackItemID = nil
        fullyPlayedFrames = 0
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        guard isActive else { return }
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

private enum RealtimeVoiceAudioEngineError: Error {
    case invalidInputFormat
    case startFailed
}
#endif
