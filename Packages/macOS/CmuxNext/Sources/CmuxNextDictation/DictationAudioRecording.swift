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
/// more and ``wav()`` returns nil: that session goes as its transcript alone,
/// and ``omission`` says why.
///
/// The tap is a synchronous real-time audio callback, so it cannot hop to an
/// actor; one unfair lock guards the state, and each tap holds it for one
/// buffer's append.
public final class DictationAudioRecording: Sendable {
    /// Why a session's audio was left out of its prompt.
    public enum Omission: String, Equatable, Sendable {
        /// Ran past ``DictationAudioRecording/maximumDuration``.
        case tooLong
        /// The input came in below 16 kHz (a narrowband headset).
        case narrowband
    }

    public static let sampleRate: Double = 16_000
    /// Two minutes: 3.84 MB of PCM, about 5 MB as the base64 a prompt carries.
    public static let maximumDuration: Double = 120

    private struct State {
        var samples: [Int16] = []
        /// Ran past ``maximumDuration`` or came in below 16 kHz.
        var omitted: Omission?
        /// The input summed toward the next output sample, and how much of it.
        var pending: (sum: Double, count: Double) = (0, 0)

        mutating func discard(_ why: Omission) {
            omitted = why
            samples = []
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State()) // lock-allow: realtime audio tap, os_unfair_lock donates

    public init() {}

    /// Folds one tap buffer in.
    public func record(_ buffer: AVAudioPCMBuffer) {
        // SAFETY: a float buffer's floatChannelData holds one pointer per channel, each to frameLength valid
        // samples owned by `buffer`, which outlives this call; append reads the first channel inside the call and
        // keeps no pointer.
        guard let channels = unsafe buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let input = unsafe UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        unsafe append(input, sampleRate: buffer.format.sampleRate)
    }

    /// Folds samples at `sampleRate` in (tests feed these directly). Each output sample is the
    /// mean of the input span it covers; an input sample that straddles two spans is split between
    /// them by weight, so a rate that is no whole multiple of 16 kHz (44.1, 24 kHz) stays level.
    /// Input below 16 kHz (a narrowband headset) is not recorded: the session goes as text alone.
    public func append(_ input: some Collection<Float>, sampleRate: Double) {
        let limit = Int(Self.sampleRate * Self.maximumDuration)
        // Unchecked: `input` need not be Sendable; the closure runs before withLockUnchecked returns.
        state.withLockUnchecked { state in
            guard state.omitted == nil else { return }
            guard sampleRate >= Self.sampleRate else { return state.discard(.narrowband) }
            // Input samples per output sample.
            let step = sampleRate / Self.sampleRate
            for value in input {
                let sample = Double(value.isFinite ? value : 0)
                var left = 1.0
                while left > 0 {
                    let take = min(left, step - state.pending.count)
                    state.pending.sum += sample * take
                    state.pending.count += take
                    left -= take
                    guard state.pending.count >= step - 1e-9 else { continue }
                    guard state.samples.count < limit else { return state.discard(.tooLong) }
                    let mean = max(-1, min(1, state.pending.sum / step))
                    state.samples.append(Int16(mean * Double(Int16.max)))
                    state.pending = (0, 0)
                }
            }
        }
    }

    /// Why ``wav()`` has nothing, when the session's audio was left out rather than silent.
    public var omission: Omission? { state.withLock { $0.omitted } }

    /// The recording as a WAV file, or nil when it is empty, ran past ``maximumDuration`` or came
    /// in below 16 kHz.
    public func wav() -> Data? {
        let samples = state.withLock { $0.omitted == nil ? $0.samples : [] }
        guard !samples.isEmpty else { return nil }
        let rate = UInt32(Self.sampleRate)
        let bytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        var data = Data(capacity: 44 + Int(bytes))
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put<T: FixedWidthInteger>(_ value: T) {
            for shift in stride(from: 0, to: T.bitWidth, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        put("RIFF"); put(36 + bytes); put("WAVE")
        put("fmt "); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        put("data"); put(bytes)
        // 16-bit PCM is little-endian.
        var pcm = [UInt8]()
        pcm.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        data.append(contentsOf: pcm)
        return data
    }
}
