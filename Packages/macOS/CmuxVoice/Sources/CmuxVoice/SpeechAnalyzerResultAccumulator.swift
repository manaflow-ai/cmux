import CoreMedia

/// Folds SpeechAnalyzer result ranges into replaceable partials and committed finals.
///
/// Speech modules may advance ``Snapshot/finalizationTime`` without publishing a
/// second result marked final. Keeping the audio ranges here lets the adapter
/// commit those older hypotheses before the next volatile phrase replaces them.
struct SpeechAnalyzerResultAccumulator: Sendable {
    /// A transcription fragment and the source-audio range it describes.
    struct Segment: Sendable, Equatable {
        let text: String
        let range: CMTimeRange
    }

    /// The range-aware metadata copied from one SpeechTranscriber result.
    struct Snapshot: Sendable {
        let segments: [Segment]
        let finalizationTime: CMTime
    }

    private var pendingSegments: [Segment] = []
    private var finalizationTime: CMTime?
    private var transcript = DictationTranscript()
    private var hasPublishedVolatileText = false

    /// Consumes one result and returns the events that are safe to expose.
    mutating func consume(_ snapshot: Snapshot) -> [DictationTranscriptionEvent] {
        for segment in snapshot.segments {
            replaceOverlappingSegment(segment)
        }

        guard snapshot.finalizationTime.isValid else {
            return emitVolatileEvent()
        }
        if let finalizationTime {
            if CMTimeCompare(snapshot.finalizationTime, finalizationTime) > 0 {
                self.finalizationTime = snapshot.finalizationTime
            }
        } else {
            finalizationTime = snapshot.finalizationTime
        }

        return emitReadyEvents()
    }

    /// Flushes every remaining fragment when the module result stream ends.
    mutating func finish() -> [DictationTranscriptionEvent] {
        pendingSegments.sort(by: Self.segmentPrecedes)
        let ready = pendingSegments
        pendingSegments.removeAll(keepingCapacity: false)
        var events: [DictationTranscriptionEvent] = []
        for segment in ready {
            if let event = finalEvent(for: segment) {
                events.append(event)
            }
        }
        if hasPublishedVolatileText {
            if events.isEmpty {
                events.append(.partial(""))
            }
            hasPublishedVolatileText = false
        }
        return events
    }

    private mutating func emitReadyEvents() -> [DictationTranscriptionEvent] {
        guard let finalizationTime else {
            return emitVolatileEvent()
        }

        let ready = pendingSegments.filter { segment in
            CMTimeCompare(segment.range.end, finalizationTime) <= 0
        }
        pendingSegments.removeAll { segment in
            CMTimeCompare(segment.range.end, finalizationTime) <= 0
        }
        var events: [DictationTranscriptionEvent] = []
        for segment in ready.sorted(by: Self.segmentPrecedes) {
            if let event = finalEvent(for: segment) {
                events.append(event)
            }
        }
        events.append(contentsOf: emitVolatileEvent(clearWhenEmpty: events.isEmpty))
        return events
    }

    private mutating func replaceOverlappingSegment(_ segment: Segment) {
        pendingSegments.removeAll { existing in
            Self.rangesOverlap(existing.range, segment.range)
        }
        guard !segment.text.isEmpty else { return }
        pendingSegments.append(segment)
        pendingSegments.sort(by: Self.segmentPrecedes)
    }

    private mutating func emitVolatileEvent(
        clearWhenEmpty: Bool = true
    ) -> [DictationTranscriptionEvent] {
        let text = pendingSegments.map(\.text).joined()
        guard !text.isEmpty else {
            guard clearWhenEmpty, hasPublishedVolatileText else { return [] }
            hasPublishedVolatileText = false
            return [.partial("")]
        }
        hasPublishedVolatileText = true
        let uncommittedText = textAfterCommittedPrefix(text)
        if uncommittedText.isEmpty {
            _ = transcript.apply(.partial(""))
            return []
        }
        _ = transcript.apply(.partial(uncommittedText))
        return [.partial(uncommittedText)]
    }

    private mutating func finalEvent(for segment: Segment) -> DictationTranscriptionEvent? {
        let text = textAfterCommittedPrefix(segment.text)
        guard !text.isEmpty else { return nil }
        return transcript.apply(.final(text)).map(DictationTranscriptionEvent.final)
    }

    private func textAfterCommittedPrefix(_ text: String) -> String {
        let committedText = transcript.committedText
        guard !committedText.isEmpty, text.hasPrefix(committedText) else {
            return text
        }
        return String(text.dropFirst(committedText.count))
    }

    private static func rangesOverlap(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        CMTimeCompare(lhs.start, rhs.end) < 0
            && CMTimeCompare(rhs.start, lhs.end) < 0
    }

    private static func segmentPrecedes(_ lhs: Segment, _ rhs: Segment) -> Bool {
        let startOrder = CMTimeCompare(lhs.range.start, rhs.range.start)
        if startOrder != 0 { return startOrder < 0 }
        return CMTimeCompare(lhs.range.end, rhs.range.end) < 0
    }
}
