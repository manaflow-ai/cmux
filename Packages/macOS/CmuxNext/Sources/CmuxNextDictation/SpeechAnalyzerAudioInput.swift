import AVFoundation
import CoreMedia
import Foundation
import os

// The handoff from the analyzer engine's real-time audio tap to its
// conversion worker (SpeechAnalyzerDictationTranscriber).

/// Raw audio-tap payload. `AVAudioNodeTapBlock` documents that callbacks
/// receive copies of node output; retaining that framework-supplied copy
/// here extends its lifetime until the single conversion worker consumes
/// it. AnalyzerInput construction happens on that worker.
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
final class AnalyzerInputBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    // The continuation is guarded by lock.
    private var continuation:
        AsyncThrowingStream<AnalyzerRawInput, any Error>.Continuation?

    func configure(
        continuation: AsyncThrowingStream<AnalyzerRawInput, any Error>.Continuation
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        guard let continuation else { return }
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

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}

/// Hands one buffer to `AVAudioConverter`'s input block.
/// The block runs synchronously inside convert(to:error:) on the
/// conversion worker, so the buffer never actually crosses threads
/// despite the @Sendable annotation.
final class AnalyzerBufferFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

extension AVAudioConverter {
    /// Converts one tap buffer to the analyzer's format.
    func convertOne(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
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
        let feed = AnalyzerBufferFeed(buffer)
        var conversionError: NSError?
        convert(to: converted, error: &conversionError) { _, outStatus in
            guard let next = feed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
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
