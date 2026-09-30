import AVFoundation
public import Foundation
import os

/// Opt-in cloud dictation engine: records the utterance on this Mac, then
/// transcribes it with OpenAI when the session stops.
///
/// Recording-then-transcribing matches how the ChatGPT desktop app dictates
/// and gives the best accuracy class OpenAI offers for recorded speech. The
/// trade-off is no live partial text: the HUD shows the level meter while
/// listening and the result lands once, on stop. Audio stays in memory and
/// is sent only to OpenAI, with the user's own key.
public actor CloudDictationTranscriber: SpeechTranscribing {
    /// Collects converted 16 kHz mono PCM from the audio tap.
    ///
    /// Lock carve-out: the `AVAudioEngine` tap is a synchronous real-time
    /// callback, so it appends inline under a short lock instead of hopping
    /// to the actor.
    private final class Recorder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        // Guarded by `lock`.
        private var samples = Data()
        private var capReached = false
        private var converter: AVAudioConverter?
        private let outputFormat: AVAudioFormat
        private let maxBytes: Int

        init(outputFormat: AVAudioFormat, maxBytes: Int) {
            self.outputFormat = outputFormat
            self.maxBytes = maxBytes
        }

        /// Returns `true` exactly once when this append fills the recording cap.
        @discardableResult
        func append(_ buffer: AVAudioPCMBuffer) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !capReached else { return false }
            guard samples.count < maxBytes else {
                capReached = true
                return true
            }
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            }
            guard let converter else { return false }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return false }
            nonisolated(unsafe) var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return false }
            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            samples.append(Data(bytes: channel[0], count: min(byteCount, maxBytes - samples.count)))
            if samples.count >= maxBytes {
                capReached = true
                return true
            }
            return false
        }

        /// Bytes recorded so far.
        var byteCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples.count
        }

        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            let result = samples
            samples = Data()
            return result
        }
    }

    static let sampleRate = 16_000
    /// OpenAI accepts uploads up to 25 MB, headers and form fields
    /// included; 16 kHz 16-bit mono is 32 KB/s, so this caps one utterance
    /// at about 12 minutes.
    static let maxRecordingBytes = 24_000_000
    /// Clips shorter than this are silence or a stray keypress; skip the
    /// network call.
    static let minimumRecordingBytes = sampleRate * 2 / 4

    private let client: OpenAITranscriptionClient
    private let levelMeter: DictationAudioLevelMeter?
    private let recorder: Recorder?
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation?
    private var isFinishing = false

    /// Creates an engine for one session.
    public init(client: OpenAITranscriptionClient, levelMeter: DictationAudioLevelMeter? = nil) {
        self.client = client
        self.levelMeter = levelMeter
        recorder = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ).map { Recorder(outputFormat: $0, maxBytes: Self.maxRecordingBytes) }
    }

    /// Uploading and transcribing takes longer than an on-device flush, and
    /// grows with the clip: a base allowance plus one second per 64 KB
    /// (about 7 minutes for a full-size clip).
    public nonisolated var stopDeadline: Duration {
        .seconds(Self.stopDeadlineBase) + .seconds(Double(recorder?.byteCount ?? 0) / 64_000)
    }

    static let stopDeadlineBase: Double = 30

    public func transcribe(
        locale: Locale
    ) async throws -> AsyncThrowingStream<DictationTranscriptionEvent, any Error> {
        guard let recorder else {
            throw DictationFailure.audioCaptureFailed("unsupported recording format")
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationFailure.audioCaptureFailed("no audio input device")
        }
        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            meter?.record(buffer)
            if recorder.append(buffer) {
                Task { [weak self] in
                    await self?.finishTranscribing()
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw DictationFailure.audioCaptureFailed(error.localizedDescription)
        }
        self.audioEngine = engine
        let (stream, continuation) = AsyncThrowingStream<DictationTranscriptionEvent, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func finishTranscribing() async {
        guard !isFinishing else {
            // A second finish (stop racing startup) only needs capture torn
            // down; the first call owns the upload.
            stopAudioEngine()
            return
        }
        isFinishing = true
        stopAudioEngine()
        levelMeter?.reset()
        guard let continuation else { return }
        let samples = recorder?.take() ?? Data()
        guard samples.count >= Self.minimumRecordingBytes else {
            continuation.finish()
            self.continuation = nil
            return
        }
        let wav = DictationWAVEncoder.wav(pcm16: samples, sampleRate: Self.sampleRate)
        do {
            let text = try await client.transcribe(wav: wav)
            if !text.isEmpty {
                continuation.yield(.final(text))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
        self.continuation = nil
    }

    private func stopAudioEngine() {
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
    }
}
