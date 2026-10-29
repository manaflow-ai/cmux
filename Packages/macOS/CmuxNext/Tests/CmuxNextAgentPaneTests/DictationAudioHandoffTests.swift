import AVFoundation
import Testing
@testable import CmuxNextDictation

/// The dictation audio handoffs (the level meter, the tap-to-worker box and the converter feed) are
/// compiler-checked `Sendable` types over one unfair lock each. These drive them
/// from many threads at once, which is what the TSan run checks, and pin their observable behavior.
@Suite(.timeLimit(.minutes(1)))
nonisolated struct DictationAudioHandoffTests {
    private static func buffer(rate: Double, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        channels[0].update(repeating: value, count: Int(frames))
        return buffer
    }

    @Test func theLevelMeterTakesUpdatesFromManyThreadsAtOnce() async {
        let meter = DictationAudioLevelMeter()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for step in 0..<500 {
                        meter.update(rms: Float((worker + step) % 10) / 10)
                        #expect((0...1).contains(meter.level))
                    }
                }
            }
        }
        // Full scale reads 1 at once (fast attack); silence then decays it (slower release).
        meter.update(rms: 1)
        #expect(meter.level == 1)
        meter.update(rms: 0)
        #expect(abs(meter.level - 0.6) < 0.0001)
    }

    @Test func theTapHandoffTakesBuffersFromManyThreadsAndDropsTapsAfterItEnds() async throws {
        let box = AnalyzerInputBox()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerRawInput, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        box.configure(continuation: continuation)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    let buffer = try Self.buffer(rate: 48_000, frames: 64, value: 0.25)
                    box.ingest(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(worker * 64), atRate: 48_000))
                }
            }
            try await group.waitForAll()
        }
        box.finish()
        box.finish()
        let late = try Self.buffer(rate: 48_000, frames: 64, value: 0.25)
        box.ingest(late, at: AVAudioTime(sampleTime: 4_096, atRate: 48_000))

        var starts: [AVAudioFramePosition] = []
        for try await input in stream {
            starts.append(input.sampleTime ?? -1)
            #expect(input.sampleRate == 48_000)
        }
        #expect(starts.sorted() == (0..<8).map { AVAudioFramePosition($0 * 64) })
    }

    @Test func endingTheHandoffWhileTapsArriveEndsTheStreamOnce() async throws {
        let box = AnalyzerInputBox()
        let (stream, continuation) = AsyncThrowingStream<AnalyzerRawInput, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        box.configure(continuation: continuation)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for step in 0..<50 {
                        let buffer = try Self.buffer(rate: 48_000, frames: 16, value: 0.1)
                        box.ingest(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(worker * 50 + step), atRate: 48_000))
                    }
                }
            }
            group.addTask { box.finish() }
            try await group.waitForAll()
        }
        var received = 0
        for try await _ in stream { received += 1 }
        #expect(received <= 8 * 50)
    }

    @Test func theConverterFeedHandsItsBufferOutOnce() throws {
        let input = try Self.buffer(rate: 48_000, frames: 256, value: 0.25)
        let feed = AnalyzerBufferFeed(AnalyzerRawInput(buffer: input, sampleTime: nil, sampleRate: nil))
        #expect(feed.take() === input)
        #expect(feed.take() == nil)
    }

    @Test func aTapBufferConvertsToTheAnalyzerRate() throws {
        let input = try Self.buffer(rate: 48_000, frames: 4_800, value: 0.25)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: input.format, to: target))
        converter.primeMethod = .none
        let converted = try converter.convertOne(
            AnalyzerRawInput(buffer: input, sampleTime: 0, sampleRate: 48_000), to: target
        )
        #expect(converted.format == target)
        // One tenth of a second: 1,600 frames at 16 kHz, less what the resampler holds back.
        #expect(converted.frameLength > 0 && converted.frameLength <= 1_616)
    }
}
