import CoreMedia

/// Folds SpeechAnalyzer result ranges into replaceable partials and committed finals.
///
/// Speech modules may advance ``Snapshot/finalizationTime`` without publishing a
/// second result marked final. Keeping the audio ranges here lets the adapter
/// commit those older hypotheses before the next volatile phrase replaces them.
struct SpeechAnalyzerResultAccumulator: Sendable {
    private static let committedSegmentLimit = 128

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
    private var committedSegments: [Segment] = []
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
        guard segment.range.isValid else { return }
        if segment.text.isEmpty {
            pendingSegments.removeAll { existing in
                Self.rangesOverlap(existing.range, segment.range)
            }
            return
        }
        // A later result can narrow its range to the still-volatile tail.
        // Keep the older enclosing segment so finalized text outside that
        // tail is not erased before its boundary is emitted.
        if pendingSegments.contains(where: { existing in
            Self.rangesOverlap(existing.range, segment.range)
                && Self.rangeContains(existing.range, segment.range)
                && existing.range != segment.range
        }) {
            return
        }
        pendingSegments.removeAll { existing in
            Self.rangesOverlap(existing.range, segment.range)
        }
        pendingSegments.append(segment)
        pendingSegments.sort(by: Self.segmentPrecedes)
    }

    private mutating func emitVolatileEvent(
        clearWhenEmpty: Bool = true
    ) -> [DictationTranscriptionEvent] {
        let text = pendingSegments
            .sorted(by: Self.segmentPrecedes)
            .map { uncommittedText(for: $0) }
            .joined()
        guard !text.isEmpty else {
            guard clearWhenEmpty, hasPublishedVolatileText else { return [] }
            hasPublishedVolatileText = false
            return [.partial("")]
        }
        hasPublishedVolatileText = true
        _ = transcript.apply(.partial(text))
        return [.partial(text)]
    }

    private mutating func finalEvent(for segment: Segment) -> DictationTranscriptionEvent? {
        let text = uncommittedText(for: segment)
        guard !text.isEmpty else { return nil }
        let event = transcript.apply(.final(text)).map(DictationTranscriptionEvent.final)
        rememberCommittedSegment(segment)
        return event
    }

    /// Removes only text whose audio range overlaps an already committed range.
    /// A repeated phrase in a later, disjoint range therefore remains intact.
    private func uncommittedText(for segment: Segment) -> String {
        let overlaps = committedSegments
            .filter { Self.rangesOverlap($0.range, segment.range) }
            .sorted(by: Self.segmentPrecedes)
        guard !overlaps.isEmpty else { return segment.text }

        let candidates = [
            overlaps.map(\.text).joined(),
            overlaps.map(\.text).joined(separator: " "),
        ].filter { !$0.isEmpty }
        for prefix in candidates where segment.text.hasPrefix(prefix) {
            return String(segment.text.dropFirst(prefix.count))
        }
        // An exact/contained range that cannot be revised after finalization
        // is already represented; suppress it instead of duplicating text.
        if committedSegments.contains(where: { existing in
            Self.rangeContains(existing.range, segment.range)
        }) {
            return ""
        }
        // If an overlapping revision does not expose a safe textual prefix,
        // wait for a later non-overlapping result rather than duplicating an
        // already committed audio range.
        return ""
    }

    private mutating func rememberCommittedSegment(_ segment: Segment) {
        committedSegments.removeAll { existing in
            Self.rangesOverlap(existing.range, segment.range)
                || Self.rangeContains(segment.range, existing.range)
        }
        committedSegments.append(segment)
        if committedSegments.count > Self.committedSegmentLimit {
            committedSegments.removeFirst(committedSegments.count - Self.committedSegmentLimit)
        }
    }

    private static func rangesOverlap(_ lhs: CMTimeRange, _ rhs: CMTimeRange) -> Bool {
        CMTimeCompare(lhs.start, rhs.end) < 0
            && CMTimeCompare(rhs.start, lhs.end) < 0
    }

    private static func rangeContains(_ outer: CMTimeRange, _ inner: CMTimeRange) -> Bool {
        CMTimeCompare(outer.start, inner.start) <= 0
            && CMTimeCompare(outer.end, inner.end) >= 0
    }

    private static func segmentPrecedes(_ lhs: Segment, _ rhs: Segment) -> Bool {
        let startOrder = CMTimeCompare(lhs.range.start, rhs.range.start)
        if startOrder != 0 { return startOrder < 0 }
        return CMTimeCompare(lhs.range.end, rhs.range.end) < 0
    }
}
