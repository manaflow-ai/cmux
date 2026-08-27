import CoreMedia
import Testing

@testable import CmuxVoice

@Suite
struct SpeechAnalyzerResultAccumulatorTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000)
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    @Test func finalizationBoundaryCommitsPriorVolatileRange() {
        var accumulator = SpeechAnalyzerResultAccumulator()
        let first = SpeechAnalyzerResultAccumulator.Snapshot(
            segments: [
                .init(text: "hello", range: range(0, 1)),
            ],
            finalizationTime: time(0)
        )
        #expect(accumulator.consume(first) == [.partial("hello")])

        // The unchanged "hello" result is now finalized even though the
        // newer result also contains a volatile second phrase.
        let second = SpeechAnalyzerResultAccumulator.Snapshot(
            segments: [
                .init(text: "hello", range: range(0, 1)),
                .init(text: " world", range: range(1, 2)),
            ],
            finalizationTime: time(1)
        )
        #expect(
            accumulator.consume(second) == [
                .final("hello"),
                .partial(" world"),
            ]
        )

        let third = SpeechAnalyzerResultAccumulator.Snapshot(
            segments: [
                .init(text: " world", range: range(1, 2)),
            ],
            finalizationTime: time(2)
        )
        #expect(accumulator.consume(third) == [.final(" world")])
    }

    @Test func finishFlushesUnfinalizedTextOnce() {
        var accumulator = SpeechAnalyzerResultAccumulator()
        let snapshot = SpeechAnalyzerResultAccumulator.Snapshot(
            segments: [
                .init(text: "tail", range: range(0, 1)),
            ],
            finalizationTime: time(0)
        )
        #expect(accumulator.consume(snapshot) == [.partial("tail")])
        #expect(accumulator.finish() == [.final("tail")])
        #expect(accumulator.finish().isEmpty)
    }

    @Test func cumulativeUntimedResultsWaitForTheirWholeRangeThenCommitOnce() {
        var accumulator = SpeechAnalyzerResultAccumulator()
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello", range: range(0, 1))],
                finalizationTime: time(0)
            )) == [.partial("hello")]
        )
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello world", range: range(0, 2))],
                finalizationTime: time(1)
            )) == [.partial("hello world")]
        )
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello world", range: range(0, 2))],
                finalizationTime: time(2)
            )) == [.final("hello world")]
        )
    }

    @Test func narrowingResultDoesNotEraseTextOutsideVolatileTail() {
        var accumulator = SpeechAnalyzerResultAccumulator()
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello world", range: range(0, 2))],
                finalizationTime: time(0)
            )) == [.partial("hello world")]
        )
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "world", range: range(1, 2))],
                finalizationTime: time(2)
            )) == [.final("hello world")]
        )
    }

    @Test func repeatedPhraseInDisjointAudioRangeIsNotDeduplicated() {
        var accumulator = SpeechAnalyzerResultAccumulator()
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello", range: range(0, 1))],
                finalizationTime: time(1)
            )) == [.final("hello")]
        )
        #expect(
            accumulator.consume(.init(
                segments: [.init(text: "hello", range: range(2, 3))],
                finalizationTime: time(3)
            )) == [.final(" hello")]
        )
    }
}
