#if os(iOS)
internal import AVFoundation
public import Foundation

/// Owns the `AVAudioEngine` + shared `AVAudioSession` lifecycle OFF the main
/// actor for the live voice-chat feature (GPT-Live): full-duplex microphone
/// capture and streamed speech playback.
///
/// Sibling of ``ComposerDictationAudioEngine`` and the same deliberate
/// concurrency carve-out (lint:allow serial-audio-queue): a private serial
/// `DispatchQueue` plus `@unchecked Sendable`, NOT an actor, because
/// `setActive`/`engine.start`/`engine.stop` are synchronous ~100-300ms
/// hardware calls (see the dictation engine's header for the full rationale,
/// https://github.com/manaflow-ai/cmux/issues/6284). All mutable state is
/// confined to ``queue``; ``teardownLocked()`` asserts the invariant.
///
/// Differences from the dictation engine, both driven by two-way voice chat:
/// the session category is `.playAndRecord` with `.voiceChat` mode (echo
/// cancellation, so the mic does not re-hear the assistant), and an
/// `AVAudioPlayerNode` renders streamed PCM16 chunks as they arrive.
public final class VoiceChatAudioEngine: @unchecked Sendable {
    /// Wire format of both capture output and playback input: mono signed
    /// 16-bit little-endian PCM at 24 kHz, matching the GPT-Live default
    /// (`{"type":"audio/pcm","rate":24000}`).
    public static let wireSampleRate: Double = 24_000

    private let queue = DispatchQueue(label: "com.cmux.voice.chat-audio")

    /// Touched only on ``queue``.
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Whether THIS owner currently holds the shared `AVAudioSession` active.
    private var isActive = false
    /// Converts captured hardware-format buffers to the 24 kHz mono wire
    /// format. Rebuilt on every start for the current input route.
    private var captureConverter: AVAudioConverter?
    /// Count of scheduled-but-unfinished playback buffers; playback activity
    /// (the "assistant is speaking" signal) is `pendingPlaybackBuffers > 0`.
    private var pendingPlaybackBuffers = 0
    /// Bumped on every ``stopPlayback()``/teardown so completion callbacks
    /// from a flushed generation cannot drive the activity signal negative.
    private var playbackGeneration = 0
    /// When muted, captured buffers are dropped before conversion. The engine
    /// keeps running so unmute is instant and the session stays configured.
    private var microphoneMuted = false
    private var onPlaybackActivity: (@Sendable (Bool) -> Void)?

    /// Playback graph format: deinterleaved Float32 mono at the wire rate.
    /// The engine resamples from here to the output route.
    private let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: VoiceChatAudioEngine.wireSampleRate,
        channels: 1
    )

    public init() {}

    /// Activate the audio session for two-way voice and start the engine off
    /// the main actor.
    ///
    /// - Parameters:
    ///   - onCapturedAudio: Called on ``queue`` with each captured chunk
    ///     converted to the wire format (24 kHz mono PCM16, even byte count).
    ///   - onPlaybackActivity: Called on ``queue`` when speech playback starts
    ///     (`true`) or drains (`false`).
    ///   - onReady: Called once on ``queue`` with whether the engine is
    ///     running. On failure the partial setup is torn down first.
    public func start(
        onCapturedAudio: @escaping @Sendable (Data) -> Void,
        onPlaybackActivity: @escaping @Sendable (Bool) -> Void,
        onReady: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async { [self] in
            do {
                self.onPlaybackActivity = onPlaybackActivity
                let session = AVAudioSession.sharedInstance()
                // `.voiceChat` enables system voice processing (echo
                // cancellation + AGC) so the assistant's own speech from the
                // speaker is not captured back into the conversation.
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetooth, .defaultToSpeaker]
                )
                try session.setActive(true)
                isActive = true

                let inputNode = engine.inputNode
                // The `.voiceChat` session mode alone does not arm the
                // voice-processing unit on an AVAudioEngine input; without it
                // the mic re-captures the assistant's own speech from the
                // speaker (it interrupts and answers itself). Must be set
                // while the engine is stopped and BEFORE reading the input
                // format, which voice processing changes. A failure degrades
                // to echo-prone audio rather than refusing to start.
                if !inputNode.isVoiceProcessingEnabled {
                    try? inputNode.setVoiceProcessingEnabled(true)
                }
                let inputFormat = inputNode.outputFormat(forBus: 0)
                guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                    teardownLocked()
                    onReady(false)
                    return
                }
                guard
                    let playbackFormat,
                    let wireFormat = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: Self.wireSampleRate,
                        channels: 1,
                        interleaved: true
                    ),
                    let converter = AVAudioConverter(from: inputFormat, to: wireFormat)
                else {
                    teardownLocked()
                    onReady(false)
                    return
                }
                captureConverter = converter

                if playerNode.engine == nil {
                    engine.attach(playerNode)
                }
                engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

                inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) {
                    [weak self] buffer, _ in
                    self?.handleCapturedBuffer(buffer)
                }
                engine.prepare()
                try engine.start()
                playerNode.play()
                self.emitCapturedAudio = onCapturedAudio
                onReady(true)
            } catch {
                teardownLocked()
                onReady(false)
            }
        }
    }

    /// Delivery target for converted capture chunks. Touched only on ``queue``
    /// (the tap hops there before converting).
    private var emitCapturedAudio: (@Sendable (Data) -> Void)?

    /// Queue playback of one wire-format chunk (24 kHz mono PCM16). Chunks
    /// play in arrival order; playback activity flips on while any chunk is
    /// scheduled and off once the queue drains.
    public func enqueuePlayback(_ data: Data) {
        queue.async { [self] in
            guard isActive, let playbackFormat else { return }
            let sampleCount = data.count / MemoryLayout<Int16>.size
            guard sampleCount > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: playbackFormat,
                    frameCapacity: AVAudioFrameCount(sampleCount)
                  ),
                  let channel = buffer.floatChannelData?[0]
            else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let samples = raw.bindMemory(to: Int16.self)
                for index in 0..<sampleCount {
                    channel[index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
                }
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)

            if pendingPlaybackBuffers == 0 {
                onPlaybackActivity?(true)
            }
            pendingPlaybackBuffers += 1
            let generation = playbackGeneration
            playerNode.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.playbackGeneration else { return }
                    self.pendingPlaybackBuffers -= 1
                    if self.pendingPlaybackBuffers == 0 {
                        self.onPlaybackActivity?(false)
                    }
                }
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    /// Drop all queued playback immediately (session teardown, or the user
    /// cut the assistant off by ending the session).
    public func stopPlayback() {
        queue.async { [self] in
            flushPlaybackLocked()
        }
    }

    /// Drop captured audio before it leaves the device. The engine keeps
    /// running so unmuting is instant.
    public func setMicrophoneMuted(_ muted: Bool) {
        queue.async { [self] in
            microphoneMuted = muted
        }
    }

    /// Stop the engine, remove the tap, flush playback, and deactivate the
    /// session. Idempotent; serialized after any in-flight start.
    public func stop() {
        queue.async { [self] in
            teardownLocked()
        }
    }

    /// Tap callback: hop to ``queue`` and convert to the wire format there so
    /// the realtime render thread never allocates or contends. The buffer is
    /// handed off before the tap returns; AVFoundation gives each tap call a
    /// fresh buffer, so the async read is safe.
    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard isActive, !microphoneMuted,
                  let converter = captureConverter,
                  let emit = emitCapturedAudio,
                  buffer.frameLength > 0
            else { return }
            let ratio = Self.wireSampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: capacity
            ) else { return }
            var fed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0,
                  let channel = converted.int16ChannelData?[0]
            else { return }
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            emit(Data(bytes: channel, count: byteCount))
        }
    }

    /// MUST run on ``queue``. Resets the playback queue and activity signal.
    private func flushPlaybackLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        playbackGeneration += 1
        let hadPending = pendingPlaybackBuffers > 0
        pendingPlaybackBuffers = 0
        playerNode.stop()
        if engine.isRunning {
            playerNode.play()
        }
        if hadPending {
            onPlaybackActivity?(false)
        }
    }

    /// MUST run on ``queue``. A no-op unless this owner activated the session.
    private func teardownLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive else { return }
        isActive = false
        flushPlaybackLocked()
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        captureConverter = nil
        emitCapturedAudio = nil
        onPlaybackActivity = nil
        microphoneMuted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
