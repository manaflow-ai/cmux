import AVFoundation
import CoreMedia
import Foundation
import os

// The handoff from the analyzer engine's real-time audio tap to its
// conversion worker (SpeechAnalyzerDictationTranscriber).

/// Raw audio-tap payload, and the one carrier that moves a tap buffer between
/// threads here: the tap hands it to the conversion worker, and the worker
/// hands it to `AVAudioConverter`'s input block (``AnalyzerBufferFeed``).
/// AnalyzerInput construction happens on that worker.
// crash-allow: AVAudioPCMBuffer is not Sendable and AsyncThrowingStream needs a Sendable element; AVAudioNodeTapBlock gives each callback its own copy of the node output, and that copy is moved (tap, then worker, then converter block), never read by two threads at once nor by a sender after its hand-off.
struct AnalyzerRawInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let sampleTime: AVAudioFramePosition?
    let sampleRate: Double?

    var bufferStartTime: CMTime? {
        guard let sampleTime, let sampleRate, sampleRate > 0 else { return nil }
        let roundedRate = min(sampleRate.rounded(), Double(Int32.max))
        return CMTime(value: sampleTime, timescale: CMTimeScale(roundedRate))
    }
}

/// The bounded handoff from the audio-thread tap to the actor.
/// Lock carve-out: the AVAudioEngine tap is a synchronous audio-thread
/// callback. It only snapshots the continuation and enqueues the tap's
/// output copy; format conversion and AnalyzerInput allocation happen on
/// the actor's worker task.
final class AnalyzerInputBox: Sendable {
    private typealias Sink = AsyncThrowingStream<AnalyzerRawInput, any Error>.Continuation
    private let sink = OSAllocatedUnfairLock<Sink?>(initialState: nil) // lock-allow: realtime audio tap, os_unfair_lock donates

    func configure(
        continuation: AsyncThrowingStream<AnalyzerRawInput, any Error>.Continuation
    ) {
        sink.withLock { $0 = continuation }
    }

    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let continuation = sink.withLock({ $0 }) else { return }
        let result = continuation.yield(
            AnalyzerRawInput(
                buffer: buffer,
                sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                sampleRate: time.isSampleTimeValid ? time.sampleRate : nil
            )
        )
        if case .dropped = result {
            continuation.finish(
                throwing: DictationFailure.audioCaptureFailed(
                    "audio input backlog"
                )
            )
        }
    }

    /// Ends the stream; a tap after this is dropped.
    func finish() {
        let ended = sink.withLock { current in
            defer { current = nil }
            return current
        }
        ended?.finish()
    }
}

/// Hands one tap buffer to `AVAudioConverter`'s input block, once. The block
/// is `@Sendable` but runs synchronously inside convert(to:error:withInputFrom:)
/// on the conversion worker, so the lock is never contended.
final class AnalyzerBufferFeed: Sendable {
    private let pending: OSAllocatedUnfairLock<AnalyzerRawInput?> // lock-allow: converter input block, one uncontended take per call

    init(_ input: AnalyzerRawInput) {
        pending = OSAllocatedUnfairLock(initialState: input)
    }

    func take() -> AVAudioPCMBuffer? {
        let input = pending.withLock { pending in
            defer { pending = nil }
            return pending
        }
        return input?.buffer
    }
}

extension AVAudioConverter {
    /// Converts one tap buffer to the analyzer's format.
    func convertOne(_ input: AnalyzerRawInput, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = input.buffer
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 16
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: max(capacity, 1)
        ) else {
            throw DictationFailure.audioCaptureFailed("audio conversion buffer unavailable")
        }
        let feed = AnalyzerBufferFeed(input)
        var conversionError: NSError?
        // SAFETY: the error pointer is a local live for the call; AVAudioConverter stores at most one NSError through
        // it and keeps no reference. The input block runs synchronously inside convert, and each `outStatus` points
        // at one status the converter owns for that block call, written once there and not kept.
        unsafe convert(to: converted, error: &conversionError) { _, outStatus in
            guard let next = feed.take() else {
                unsafe outStatus.pointee = .noDataNow
                return nil
            }
            unsafe outStatus.pointee = .haveData
            return next
        }
        if let conversionError {
            throw DictationFailure.audioCaptureFailed(conversionError.localizedDescription)
        }
        guard converted.frameLength > 0 else {
            throw DictationFailure.audioCaptureFailed("audio conversion produced no frames")
        }
        return converted
    }
}
