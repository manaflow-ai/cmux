public import AVFoundation
public import Foundation
import os

/// The session's own audio, kept for a harness that takes voice input
/// (`promptCapabilities.audio`): 16 kHz mono 16-bit PCM, what speech models
/// expect, finished as one WAV file.
///
/// The level meter feeds it each tap buffer (``DictationAudioLevelMeter/recording``).
/// Each buffer is downmixed to its first channel and box-averaged to 16 kHz in
/// the tap, so the session holds 32 KB a second, never the input's rate.
/// Past ``maximumDuration``, or from input below 16 kHz, it keeps nothing
/// more and ``wav()`` returns nil: that session goes as its transcript alone.
///
/// Lock carve-out: the tap is a synchronous real-time audio callback, so it
/// cannot hop to an actor. The lock guards an append to one buffer.
public final class DictationAudioRecording: @unchecked Sendable {
    public static let sampleRate: Double = 16_000
    /// Two minutes: 3.84 MB of PCM, about 5 MB as the base64 a prompt carries.
    public static let maximumDuration: Double = 120

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`.
    private var samples: [Int16] = []
    /// Ran past ``maximumDuration`` or came in below 16 kHz.
    private var discarded = false
    /// The input samples summed toward the next output sample, and how many.
    private var pending: (sum: Double, count: Double) = (0, 0)

    public init() {}

    /// Folds one tap buffer in.
    public func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let input = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        append(input, sampleRate: buffer.format.sampleRate)
    }

    /// Folds samples at `sampleRate` in (tests feed these directly). Each output sample is the
    /// mean of the input span it covers; an input sample that straddles two spans is split between
    /// them by weight, so a rate that is no whole multiple of 16 kHz (44.1, 24 kHz) stays level.
    /// Input below 16 kHz (a narrowband headset) is not recorded: the session goes as text alone.
    public func append(_ input: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let limit = Int(Self.sampleRate * Self.maximumDuration)
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        guard sampleRate >= Self.sampleRate else {
            discard()
            return
        }
        // Input samples per output sample.
        let step = sampleRate / Self.sampleRate
        for value in input {
            let sample = Double(value.isFinite ? value : 0)
            var left = 1.0
            while left > 0 {
                let take = min(left, step - pending.count)
                pending.sum += sample * take
                pending.count += take
                left -= take
                guard pending.count >= step - 1e-9 else { continue }
                guard samples.count < limit else {
                    discard()
                    return
                }
                let mean = max(-1, min(1, pending.sum / step))
                samples.append(Int16(mean * Double(Int16.max)))
                pending = (0, 0)
            }
        }
    }

    /// Keeps nothing more; ``wav()`` returns nil. Called with `lock` held.
    private func discard() {
        discarded = true
        samples = []
    }

    /// The recording as a WAV file, or nil when it is empty or ran past ``maximumDuration``.
    public func wav() -> Data? {
        lock.lock()
        let samples = discarded ? [] : samples
        lock.unlock()
        guard !samples.isEmpty else { return nil }
        let rate = UInt32(Self.sampleRate)
        let bytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(bytes))
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put(36 + bytes); put("WAVE")
        put("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        put("data"); put(bytes)
        // 16-bit PCM is little-endian, as every Mac stores an Int16.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
