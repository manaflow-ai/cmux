import AVFoundation
import CoreMedia
import Testing

@testable import CmuxNextDictation

/// The start times the analyzer gets. It rejects a buffer that starts before
/// the previous one ended ("Audio input timestamp overlaps or precedes prior
/// audio input"), which resampling can cause: a 4096-frame buffer at
/// 22,050 Hz can come out as 2973 frames at 16 kHz, a little longer than the
/// time to the next buffer's capture.
@Suite struct AnalyzerTimelineTests {
    private static func seconds(_ time: CMTime?) -> Double { time.map(CMTimeGetSeconds) ?? -1 }

    @Test func aResampledBufferThatRunsLongPushesTheNextStartBack() {
        var timeline = AnalyzerTimeline()
        let first = timeline.start(at: CMTime(value: 0, timescale: 22_050), frames: 2_973, sampleRate: 16_000)
        let second = timeline.start(at: CMTime(value: 4_096, timescale: 22_050), frames: 2_972, sampleRate: 16_000)
        #expect(Self.seconds(first) == 0)
        // 4096 / 22050 s is before 2973 / 16000 s, where the first buffer ended.
        #expect(CMTimeCompare(second ?? .invalid, CMTime(value: 2_973, timescale: 16_000)) == 0)
    }

    @Test func contiguousBuffersKeepTheirTimes() {
        var timeline = AnalyzerTimeline()
        _ = timeline.start(at: CMTime(value: 0, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        let next = timeline.start(at: CMTime(value: 1_600, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(CMTimeCompare(next ?? .invalid, CMTime(value: 1_600, timescale: 16_000)) == 0)
    }

    /// A dropped buffer leaves a real gap; the timeline keeps it.
    @Test func aGapIsKept() {
        var timeline = AnalyzerTimeline()
        _ = timeline.start(at: CMTime(value: 0, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        let later = timeline.start(at: CMTime(value: 4_800, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(Self.seconds(later) == 0.3)
    }

    @Test func aBufferWithoutATimeHasNone() {
        var timeline = AnalyzerTimeline()
        _ = timeline.start(at: CMTime(value: 0, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(timeline.start(at: nil, frames: 1_600, sampleRate: 16_000) == nil)
    }

    /// The analyzer places a buffer without a time right after the previous
    /// one, so the next timed buffer still starts after both.
    @Test func aBufferWithoutATimeStillTakesItsPlace() {
        var timeline = AnalyzerTimeline()
        _ = timeline.start(at: CMTime(value: 0, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        _ = timeline.start(at: nil, frames: 1_600, sampleRate: 16_000)
        let next = timeline.start(at: CMTime(value: 2_400, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(CMTimeCompare(next ?? .invalid, CMTime(value: 3_200, timescale: 16_000)) == 0)
    }

    @Test func anInputIsTimedAtItsBuffersRate() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_973))
        buffer.frameLength = 2_973
        var timeline = AnalyzerTimeline()
        _ = timeline.input(buffer, capturedAt: CMTime(value: 0, timescale: 22_050))
        let next = timeline.input(buffer, capturedAt: CMTime(value: 4_096, timescale: 22_050))
        #expect(CMTimeCompare(next.bufferStartTime ?? .invalid, CMTime(value: 2_973, timescale: 16_000)) == 0)
    }
}
