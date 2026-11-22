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
        var start = time
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
