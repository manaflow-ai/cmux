import CoreMedia
import Foundation
import Speech

/// Delivers SpeechAnalyzer results while preserving range finalization metadata.
@available(macOS 26.0, *)
actor SpeechAnalyzerResultConsumer {
    private let transcriber: SpeechTranscriber
    private let continuation:
        AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation

    init(
        transcriber: SpeechTranscriber,
        continuation: AsyncThrowingStream<DictationTranscriptionEvent, any Error>.Continuation
    ) {
        self.transcriber = transcriber
        self.continuation = continuation
    }

    func run() async {
        var accumulator = SpeechAnalyzerResultAccumulator()
        do {
            for try await result in transcriber.results {
                for event in accumulator.consume(Self.snapshot(for: result)) {
                    guard yield(event) else { return }
                }
            }
            for event in accumulator.finish() {
                guard yield(event) else { return }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(
                throwing: DictationFailure.transcriptionFailed(error.localizedDescription)
            )
        }
    }

    private func yield(_ event: DictationTranscriptionEvent) -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped(let dropped):
            // Partials are replaceable HUD state. A dropped final would lose
            // text that can never be reconstructed, so terminate the stream.
            guard case .final = dropped else { return true }
            continuation.finish(
                throwing: DictationFailure.transcriptionFailed(
                    "recognition output backlog"
                )
            )
            return false
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    private static func snapshot(
        for result: SpeechTranscriber.Result
    ) -> SpeechAnalyzerResultAccumulator.Snapshot {
        let attributedText = result.text
        var pieces: [(text: String, range: CMTimeRange?)] = []
        var hasTimedRuns = false
        for run in attributedText.runs {
            let text = String(attributedText[run.range].characters)
            guard !text.isEmpty else { continue }
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            pieces.append((text: text, range: range))
            if range != nil {
                hasTimedRuns = true
            } else {
                continue
            }
        }
        var segments: [SpeechAnalyzerResultAccumulator.Segment]
        if !hasTimedRuns {
            segments = attributedText.characters.isEmpty
                ? []
                : [
                    SpeechAnalyzerResultAccumulator.Segment(
                        text: String(attributedText.characters),
                        range: result.range
                    )
                ]
        } else {
            // A missing attribute is normally whitespace or punctuation. Keep
            // it adjacent to the nearest timed run; attaching it to the whole
            // result range would overlap and erase every precisely ranged
            // fragment during replacement.
            segments = []
            var leadingUntimedText = ""
            for piece in pieces {
                guard let range = piece.range else {
                    if segments.isEmpty {
                        leadingUntimedText += piece.text
                    } else {
                        let last = segments.removeLast()
                        segments.append(
                            SpeechAnalyzerResultAccumulator.Segment(
                                text: last.text + piece.text,
                                range: last.range
                            )
                        )
                    }
                    continue
                }
                let segment = SpeechAnalyzerResultAccumulator.Segment(
                    text: leadingUntimedText + piece.text,
                    range: range
                )
                if let last = segments.last, last.range == range {
                    segments[segments.index(before: segments.endIndex)] =
                        SpeechAnalyzerResultAccumulator.Segment(
                            text: last.text + segment.text,
                            range: range
                        )
                } else {
                    segments.append(segment)
                }
                leadingUntimedText = ""
            }
            if !leadingUntimedText.isEmpty, !segments.isEmpty {
                let last = segments.removeLast()
                segments.append(
                    SpeechAnalyzerResultAccumulator.Segment(
                        text: last.text + leadingUntimedText,
                        range: last.range
                    )
                )
            }
        }
        return SpeechAnalyzerResultAccumulator.Snapshot(
            segments: segments,
            finalizationTime: result.resultsFinalizationTime
        )
    }
}
