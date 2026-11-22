public import AVFoundation
import Foundation
import os

/// Microphone input level for the dictation meter.
///
/// Engines call ``record(_:)`` from their `AVAudioEngine` tap, once per
/// buffer (about 12 times a second), and each call yields the new level to
/// ``levels``. The meter moves only while audio arrives: no timer polls it.
/// Levels travel outside the transcription event stream on purpose: that
/// stream is bounded, and meter updates must never push a final out of it.
///
/// Lock carve-out: the tap is a synchronous real-time audio callback, so it
/// cannot hop to an actor. The lock guards one `Float` with a constant-time
/// critical section.
public final class DictationAudioLevelMeter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`.
    private var storedLevel: Float = 0

    /// Quietest level shown, in dBFS. Anything below reads as silence.
    private static let floorDecibels: Float = -55

    /// Each new level, newest only: a slow reader skips stale levels.
    public let levels: AsyncStream<Float>
    private let continuation: AsyncStream<Float>.Continuation

    /// Creates a meter reading zero.
    public init() {
        (levels, continuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Normalized input level in `0...1`, where `0` is silence.
    public var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return storedLevel
    }

    /// Folds one tap buffer into the meter.
    public func record(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        update(rms: Self.rootMeanSquare(samples))
    }

    /// Sets the level from a precomputed RMS amplitude (`0...1`). Fixture
    /// engines use this to animate the meter without a microphone.
    public func update(rms: Float) {
        let next = Self.normalizedLevel(rms: rms)
        lock.lock()
        // Fast attack, slower release, so the meter reads as speech rather
        // than flicker.
        storedLevel = next > storedLevel ? next : storedLevel * 0.6 + next * 0.4
        let level = storedLevel
        lock.unlock()
        continuation.yield(level)
    }

    /// Ends ``levels``; the session is over.
    public func finish() {
        continuation.finish()
    }

    static func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func normalizedLevel(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let clamped = min(0, max(floorDecibels, decibels))
        return (clamped - floorDecibels) / -floorDecibels
    }
}
