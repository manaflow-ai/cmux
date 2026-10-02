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

    /// `silence` as the analyzer's first input, at time zero. SpeechAnalyzer
    /// runs its first chunk (about a second) on whatever audio it has when
    /// it starts and never revisits the rest of that chunk, so speech in the
    /// first second of capture was lost. Heard all at once, the lead-in fills
    /// that chunk; captured audio follows it.
    mutating func leadIn(_ silence: AVAudioPCMBuffer) -> AnalyzerInput {
        let rate = CMTimeScale(min(silence.format.sampleRate.rounded(), Double(Int32.max)))
        offset = CMTime(value: CMTimeValue(silence.frameLength), timescale: rate)
        end = offset
        return AnalyzerInput(buffer: silence, bufferStartTime: .zero)
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
    /// `seconds` of silence in `format`, for ``AnalyzerTimeline/leadIn(_:)``.
    static func silence(_ format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        return buffer
    }
}
