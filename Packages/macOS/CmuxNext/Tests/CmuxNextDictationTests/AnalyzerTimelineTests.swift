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

    /// The buffer is in the analyzer's own format (what
    /// `SpeechAnalyzer.bestAvailableAudioFormat` returns for the transcriber:
    /// 16 kHz mono Int16), as every buffer the engine feeds it is. On macOS 27
    /// `AnalyzerInput` traps on a Float32 buffer.
    @Test func anInputIsTimedAtItsBuffersRate() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_973))
        buffer.frameLength = 2_973
        var timeline = AnalyzerTimeline()
        _ = timeline.input(buffer, capturedAt: CMTime(value: 0, timescale: 22_050))
        let next = timeline.input(buffer, capturedAt: CMTime(value: 4_096, timescale: 22_050))
        #expect(CMTimeCompare(next.bufferStartTime ?? .invalid, CMTime(value: 2_973, timescale: 16_000)) == 0)
    }

    /// SpeechAnalyzer transcribes nothing in about the first 1.1 s of audio
    /// it hears, and digital silence does not count toward that span, so the
    /// lead-in is a faint noise floor in several buffers.
    @Test func theLeadInIsAFaintNoiseFloor() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let pieces = AVAudioPCMBuffer.noiseFloor(format, seconds: 1.5, pieces: 10)
        #expect(pieces.count == 10)
        #expect(pieces.reduce(0) { $0 + Int($1.frameLength) } == 24_000)
        let samples = pieces.flatMap { piece in
            (0..<Int(piece.frameLength)).map { Int(piece.int16ChannelData?[0][$0] ?? 0) }
        }
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { abs($0) <= 128 })
    }

    @Test func capturedAudioFollowsTheLeadIn() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        var timeline = AnalyzerTimeline()
        let lead = timeline.leadIn(AVAudioPCMBuffer.noiseFloor(format, seconds: 1.5, pieces: 10))
        for (index, input) in lead.enumerated() {
            #expect(CMTimeCompare(input.bufferStartTime ?? .invalid, CMTime(value: CMTimeValue(index * 2_400), timescale: 16_000)) == 0)
        }
        let first = timeline.start(at: CMTime(value: 0, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(CMTimeCompare(first ?? .invalid, CMTime(value: 24_000, timescale: 16_000)) == 0)
        let next = timeline.start(at: CMTime(value: 1_600, timescale: 16_000), frames: 1_600, sampleRate: 16_000)
        #expect(CMTimeCompare(next ?? .invalid, CMTime(value: 25_600, timescale: 16_000)) == 0)
    }
}
