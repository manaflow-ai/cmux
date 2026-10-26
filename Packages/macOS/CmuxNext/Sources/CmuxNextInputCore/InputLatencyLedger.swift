/// Closed input latency slots handed over together: what one ``InputLatencyRing/takeBatch()``
/// returned, the refresh interval to judge scroll frames against, and how many slots were lost
/// before the batch (the ring's and the table's drops since the previous batch).
public struct InputLatencyBatch: Sendable, Equatable {
    /// The closed slots, oldest first.
    public var slots: [InputLatencySlot]
    /// The display refresh interval in nanoseconds (0 when unknown: scroll frames are skipped).
    public var vsyncNanos: UInt64
    /// Slots lost before this batch: overwritten in the ring or refused by a full table.
    public var droppedBefore: UInt64

    public init(slots: [InputLatencySlot], vsyncNanos: UInt64, droppedBefore: UInt64 = 0) {
        self.slots = slots
        self.vsyncNanos = vsyncNanos
        self.droppedBefore = droppedBefore
    }
}

/// Folds closed input latency slots into histograms per kind x target x entrypoint x
/// presentation source: the total latency (Chrome `EventLatency.<Type>.TotalLatency`) and, per
/// stage, the time since the stage the input reached just before it (Chrome's EventLatency stage
/// breakdowns, cc/metrics/compositor_frame_reporter.cc). Scroll frames also go through Chrome's
/// scroll jank formula (``ScrollJankTracker``).
///
/// Follows cc's `EventMetrics` rules (cc/metrics/event_metrics.h): a slot whose input caused no
/// frame update is dropped, except keys (Chrome keeps `EventLatency.KeyPressed`); a stage the
/// input skipped (0) adds no sample anywhere; a slot without a presented time adds no total.
///
/// A value with no lock and no clock reads: its owner (`InputLatencyReporter` in
/// CmuxNextControl) keeps it in an actor and folds batches off the main thread. Rows are bounded by
/// the enums: at most 13 kinds x 9 targets x 2 entrypoints x 4 sources.
public struct InputLatencyLedger: Sendable, Equatable {
    /// One row's key.
    public struct Key: Sendable, Hashable {
        public var kind: InputEventKind
        public var target: InputTarget
        public var entrypoint: InputEntrypoint
        public var presentationSource: InputPresentationSource

        public init(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                    presentationSource: InputPresentationSource) {
            self.kind = kind
            self.target = target
            self.entrypoint = entrypoint
            self.presentationSource = presentationSource
        }
    }

    /// One row: the slots counted, their total latency and each stage's delta.
    public struct Row: Sendable, Equatable {
        /// Slots counted in the row.
        public internal(set) var count: UInt64 = 0
        /// Oldest OS event to presented frame, for slots that reached both.
        public internal(set) var total = InputLatencyHistogram()
        /// Per ``InputStage`` raw value: the time since the stage reached just before it.
        /// ``InputStage/generated`` starts every slot and stays empty.
        public internal(set) var stages = [InputLatencyHistogram](repeating: InputLatencyHistogram(), count: InputLatencyLedger.stageCount)

        /// The histogram of `stage`'s deltas.
        public subscript(stage: InputStage) -> InputLatencyHistogram {
            stages[Int(stage.rawValue)]
        }
    }

    /// Read once: a synthesized `allCases` builds a new array on each read.
    static let stageCount = InputStage.allCases.count
    private static let stagesInOrder = InputStage.allCases

    /// The rows.
    public private(set) var rows: [Key: Row] = [:]
    /// Slots received, kept or not.
    public private(set) var slotsReceived: UInt64 = 0
    /// Non-key slots dropped because their input caused no frame update.
    public private(set) var slotsWithoutFrameUpdate: UInt64 = 0
    /// Slots lost before they reached the ledger (ring, table or hand-off drops).
    public private(set) var slotsDropped: UInt64 = 0
    /// Chrome's scroll jank counts over the scroll frames of person input.
    public private(set) var scrollJank = ScrollJankTracker()

    /// A scroll frame being gathered: scroll update slots with the same presented time are one frame.
    private struct ScrollFrame: Sendable, Equatable {
        /// The oldest input's OS time.
        var first: UInt64
        /// The newest input's OS time.
        var last: UInt64
        var presented: UInt64
    }

    private var pendingFrame: ScrollFrame?

    public init() {}

    /// Counts `count` slots lost before the ledger saw them.
    public mutating func noteDropped(_ count: UInt64) {
        slotsDropped &+= count
    }

    /// Folds `batch` in.
    public mutating func fold(_ batch: InputLatencyBatch) {
        noteDropped(batch.droppedBefore)
        for slot in batch.slots { fold(slot, vsyncNanos: batch.vsyncNanos) }
        flushScrollFrame(vsyncNanos: batch.vsyncNanos)
    }

    private mutating func fold(_ slot: InputLatencySlot, vsyncNanos: UInt64) {
        slotsReceived &+= 1
        // Scroll begins seldom update a frame, so the scroll's life is read before the drop below.
        if slot.entrypoint == .person { trackScroll(slot, vsyncNanos: vsyncNanos) }
        guard slot.causedFrameUpdate || slot.kind.isKey else {
            slotsWithoutFrameUpdate &+= 1
            return
        }
        let key = Key(kind: slot.kind, target: slot.target, entrypoint: slot.entrypoint, presentationSource: slot.presentationSource)
        Self.count(slot, in: &rows[key, default: Row()])
    }

    private static func count(_ slot: InputLatencySlot, in row: inout Row) {
        row.count &+= 1
        if let total = slot.totalNanos { row.total.record(nanos: total) }
        for stage in stagesInOrder where stage != .generated {
            guard let delta = delta(of: stage, in: slot) else { continue }
            row.stages[Int(stage.rawValue)].record(nanos: delta)
        }
    }

    /// The time from the stage `slot` reached just before `stage` to `stage`, or nil when `stage`
    /// was skipped. Stages are ordered by time, not by declaration: a terminal key's echo comes
    /// back before its frame is submitted. Equal times keep declaration order.
    static func delta(of stage: InputStage, in slot: InputLatencySlot) -> UInt64? {
        let time = slot[stage]
        guard time != 0 else { return nil }
        var previous: UInt64 = 0
        for other in stagesInOrder where other != stage {
            let otherTime = slot[other]
            guard otherTime != 0 else { continue }
            let before = otherTime < time || (otherTime == time && other.rawValue < stage.rawValue)
            if before, otherTime >= previous { previous = otherTime }
        }
        guard previous != 0 else { return nil }
        return time - previous
    }

    // MARK: scroll jank

    private mutating func trackScroll(_ slot: InputLatencySlot, vsyncNanos: UInt64) {
        switch slot.kind {
        case .scrollBegin:
            flushScrollFrame(vsyncNanos: vsyncNanos)
            scrollJank.scrollStarted()
        case .scrollFirstUpdate:
            flushScrollFrame(vsyncNanos: vsyncNanos)
            scrollJank.scrollStarted()
            gatherScrollFrame(slot, vsyncNanos: vsyncNanos)
        case .scrollUpdate, .scrollMomentum:
            gatherScrollFrame(slot, vsyncNanos: vsyncNanos)
        case .keyPress, .keyRelease, .flags, .mousePress, .mouseRelease, .pointerMove, .drag, .scrollEnd, .magnify:
            return
        }
    }

    private mutating func gatherScrollFrame(_ slot: InputLatencySlot, vsyncNanos: UInt64) {
        guard slot.presented != 0, slot.generated != 0 else { return }
        let last = max(slot.lastGenerated, slot.generated)
        if let frame = pendingFrame, frame.presented == slot.presented {
            pendingFrame = ScrollFrame(first: min(frame.first, slot.generated), last: max(frame.last, last), presented: frame.presented)
            return
        }
        flushScrollFrame(vsyncNanos: vsyncNanos)
        pendingFrame = ScrollFrame(first: slot.generated, last: last, presented: slot.presented)
    }

    private mutating func flushScrollFrame(vsyncNanos: UInt64) {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        scrollJank.framePresented(firstGenerated: frame.first, lastGenerated: frame.last, presented: frame.presented, vsyncNanos: vsyncNanos)
    }

    // MARK: report

    /// The ledger as report fields; the most frequent row first (then by key).
    public var snapshot: InputLatencySnapshot {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return Self.order(lhs.key) < Self.order(rhs.key)
        }
        return InputLatencySnapshot(
            bucketEdgesMilliseconds: InputLatencyBuckets.edgesNanos.map { Double($0) / 1_000_000 },
            slotsReceived: slotsReceived,
            slotsWithoutFrameUpdate: slotsWithoutFrameUpdate,
            slotsDropped: slotsDropped,
            rows: sorted.map { key, row in
                InputLatencySnapshot.Row(
                    kind: String(describing: key.kind),
                    target: String(describing: key.target),
                    entrypoint: String(describing: key.entrypoint),
                    presentationSource: String(describing: key.presentationSource),
                    count: row.count,
                    total: row.total.snapshot,
                    stages: Self.stagesInOrder.compactMap { stage -> InputLatencySnapshot.Stage? in
                        let histogram = row[stage]
                        guard histogram.count > 0 else { return nil }
                        return InputLatencySnapshot.Stage(stage: String(describing: stage), histogram: histogram.snapshot)
                    }
                )
            },
            scrollJank: InputLatencySnapshot.ScrollJank(
                presentedFrames: scrollJank.presentedFrames,
                delayedFrames: scrollJank.delayedFrames,
                skippedFrames: scrollJank.skippedFrames,
                histograms: scrollJank.histograms.snapshot
            )
        )
    }

    private static func order(_ key: Key) -> UInt32 {
        UInt32(key.kind.rawValue) << 24 | UInt32(key.target.rawValue) << 16
            | UInt32(key.entrypoint.rawValue) << 8 | UInt32(key.presentationSource.rawValue)
    }
}
