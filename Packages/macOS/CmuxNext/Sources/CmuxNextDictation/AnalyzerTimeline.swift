import AVFoundation
import CoreMedia
import Speech

/// Start times for the analyzer's input, in the order the buffers are fed.
/// SpeechAnalyzer rejects a buffer that starts before the previous one
/// ended, and resampling can make a buffer a frame longer than the time to
/// the next buffer's capture. A start never precedes the previous end; a
/// real gap (a dropped tap buffer) is kept.
struct AnalyzerTimeline {
    /// Where the previous buffer ended.
    private var end: CMTime?
    /// How far captured audio sits after the lead-in on the analyzer's clock.
    private var offset = CMTime.zero

    /// `buffers` as the analyzer's first input, from time zero. SpeechAnalyzer
    /// transcribes nothing in about the first 1.1 s of audio it hears, and
    /// digital silence does not count toward that span, so words spoken in
    /// the first second of a session were lost. A faint noise floor fills
    /// that span; captured audio follows it.
    mutating func leadIn(_ buffers: [AVAudioPCMBuffer]) -> [AnalyzerInput] {
        var time = CMTime.zero
        let inputs = buffers.map { buffer in
            defer {
                let rate = CMTimeScale(min(buffer.format.sampleRate.rounded(), Double(Int32.max)))
                time = CMTimeAdd(time, CMTime(value: CMTimeValue(buffer.frameLength), timescale: rate))
            }
            return AnalyzerInput(buffer: buffer, bufferStartTime: time)
        }
        offset = time
        end = time
        return inputs
    }

    /// The start time to give a buffer of `frames` frames at `sampleRate`
    /// that was captured at `time`. A buffer without a time keeps none: the
    /// analyzer places it right after the previous one, so the timeline
    /// moves on by its length. A rate that is not positive (never the case
    /// for a valid format) resets the timeline.
    mutating func start(at time: CMTime?, frames: AVAudioFrameCount, sampleRate: Double) -> CMTime? {
        guard sampleRate > 0 else {
            end = nil
            return time
        }
        let rate = CMTimeScale(min(sampleRate.rounded(), Double(Int32.max)))
        let length = CMTime(value: CMTimeValue(frames), timescale: rate)
        guard let time else {
            end = end.map { CMTimeAdd($0, length) }
            return nil
        }
        var start = CMTimeAdd(time, offset)
        if let end, CMTimeCompare(start, end) < 0 { start = end }
        end = CMTimeAdd(start, length)
        return start
    }

    /// `buffer`, already in the analyzer's format, as the analyzer's next input.
    mutating func input(_ buffer: AVAudioPCMBuffer, capturedAt time: CMTime?) -> AnalyzerInput {
        let start = start(at: time, frames: buffer.frameLength, sampleRate: buffer.format.sampleRate)
        return AnalyzerInput(buffer: buffer, bufferStartTime: start)
    }
}

extension AVAudioPCMBuffer {
    /// `seconds` of faint noise (about -50 dBFS) in `format`, split into
    /// `pieces` buffers, for ``AnalyzerTimeline/leadIn(_:)``. The noise is
    /// the same every time.
    static func noiseFloor(_ format: AVAudioFormat, seconds: Double, pieces: Int) -> [AVAudioPCMBuffer] {
        let total = Int((format.sampleRate * seconds).rounded())
        guard total > 0, pieces > 0 else { return [] }
        var state: UInt32 = 0x9E37_79B9
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.003
        }
        return (0..<pieces).compactMap { piece in
            let frames = AVAudioFrameCount(total * (piece + 1) / pieces - total * piece / pieces)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    if let data = buffer.floatChannelData {
                        data[channel][frame] = next()
                    } else if let data = buffer.int16ChannelData {
                        data[channel][frame] = Int16(next() * 32_767)
                    }
                }
            }
            return buffer
        }
    }
}
