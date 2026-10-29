/// Closed input latency slots handed over together: what one ``InputLatencyRing/takeBatch()``
/// returned, the refresh interval to judge scroll frames against, the display it was presented
/// on, and the producer's lost-slot counter when the batch was taken.
public struct InputLatencyBatch: Sendable, Equatable {
    /// The closed slots, oldest first.
    public var slots: [InputLatencySlot]
    /// The display refresh interval in nanoseconds (0 when unknown: scroll frames are skipped).
    public var vsyncNanos: UInt64
    /// Slots the producer lost since it was made: its ring's and its table's cumulative
    /// `droppedCount`s added up. The ledger counts the growth since the last batch it folded, so
    /// a batch lost on the way loses no drop count: the next one carries it.
    public var droppedTotal: UInt64
    /// The display the slots were presented on: their rows carry it as a label.
    public var display: InputDisplayClass

    public init(slots: [InputLatencySlot], vsyncNanos: UInt64, droppedTotal: UInt64 = 0,
                display: InputDisplayClass = .unknown) {
        self.slots = slots
        self.vsyncNanos = vsyncNanos
        self.droppedTotal = droppedTotal
        self.display = display
    }
}

/// Folds closed input latency slots into histograms per kind x target x entrypoint x
/// presentation source x display: the total latency (Chrome `EventLatency.<Type>.TotalLatency`) and, per
/// stage, the time since the stage the input reached just before it (Chrome's EventLatency stage
/// breakdowns, cc/metrics/compositor_frame_reporter.cc). Scroll frames also go through Chrome's
/// scroll jank formula (``ScrollJankTracker``), and key and pointer slots pair into INP-style
/// interactions (``InteractionLatency``).
///
/// Follows cc's `EventMetrics` rules (cc/metrics/event_metrics.h): a slot whose input caused no
/// frame update is dropped, except keys (Chrome keeps `EventLatency.KeyPressed`); a stage the
/// input skipped (0) adds no sample anywhere; a slot without a presented time adds no total.
///
/// A value with no lock and no clock reads: its owner (`InputLatencyReporter` in
/// CmuxNextControl) keeps it in an actor and folds batches off the main thread. Rows are bounded by
/// the enums: at most 13 kinds x 9 targets x 2 entrypoints x 4 sources, per display.
public struct InputLatencyLedger: Sendable, Equatable {
    /// One row's key.
    public struct Key: Sendable, Hashable {
        public var kind: InputEventKind
        public var target: InputTarget
        public var entrypoint: InputEntrypoint
        public var presentationSource: InputPresentationSource
        public var display: InputDisplayClass

        public init(kind: InputEventKind, target: InputTarget, entrypoint: InputEntrypoint,
                    presentationSource: InputPresentationSource, display: InputDisplayClass = .unknown) {
            self.kind = kind
            self.target = target
            self.entrypoint = entrypoint
            self.presentationSource = presentationSource
            self.display = display
        }
    }

    /// One row: the slots counted, their total latency and each stage's delta.
    public struct Row: Sendable, Equatable {
        /// Slots counted in the row.
        public internal(set) var count: UInt64 = 0
        /// Oldest OS event to presented frame, for slots that reached both.
        public internal(set) var total = InputLatencyHistogram()
        /// Per ``InputStage`` raw value: the time since the stage reached just before it.
        /// ``InputStage/generated`` starts every slot and stays empty, and so does
        /// ``InputStage/lastGenerated``, which is scroll jank metadata, not a pipeline stage.
        public internal(set) var stages = [InputLatencyHistogram](repeating: InputLatencyHistogram(), count: InputLatencyLedger.stageCount)

        /// The histogram of `stage`'s deltas.
        public subscript(stage: InputStage) -> InputLatencyHistogram {
            stages[Int(stage.rawValue)]
        }

        /// Adds `other`'s counts.
        mutating func add(_ other: Row) {
            count &+= other.count
            total.add(other.total)
            for index in stages.indices { stages[index].add(other.stages[index]) }
        }
    }

    /// Read once: a synthesized `allCases` builds a new array on each read.
    static let stageCount = InputStage.allCases.count
    private static let stagesInOrder = InputStage.allCases
    /// The stages an input passes through, in declaration order. ``InputStage/lastGenerated`` is
    /// left out: as Chrome's `last_input_generation_ts`, it feeds scroll jank only, and every stage
    /// delta is measured from the oldest event (cc/metrics/compositor_frame_reporter.cc).
    static let pipelineStages = InputStage.allCases.filter { $0 != .lastGenerated }

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
    /// The person's interactions (cmux's INP): every key and pointer slot, a frame update or not.
    public private(set) var interactions = InteractionLatency()

    /// A scroll frame being gathered: scroll update slots with the same presented time are one
    /// frame, even when a batch boundary falls between them.
    private struct ScrollFrame: Sendable, Equatable {
        /// The oldest input's OS time.
        var first: UInt64
        /// The newest input's OS time.
        var last: UInt64
        var presented: UInt64
        /// The refresh interval of the batch that started the frame.
        var vsyncNanos: UInt64
    }

    /// The frame being gathered. It stays across batches and is counted when a slot with another
    /// presented time or the next scroll's start arrives, so a snapshot leaves it out.
    private var pendingFrame: ScrollFrame?
    /// The last ``InputLatencyBatch/droppedTotal`` folded.
    private var lastDroppedTotal: UInt64 = 0

    public init() {}

    /// Starts every count over (`debug.input reset`). It keeps the producer's last drop total, so the
    /// next batch adds only the slots lost after the reset.
    public mutating func reset() {
        let baseline = lastDroppedTotal
        self = InputLatencyLedger()
        lastDroppedTotal = baseline
    }

    /// Moves the counts out and returns them as a ledger of counts only: the rows, the slot counters,
    /// the scroll jank counts and histograms and the closed interactions start again at zero. What
    /// is in progress stays: the scroll frame being gathered, the scroll in progress, the fixed
    /// window not yet full, the key and click not yet released and the producer's drop baseline,
    /// so the next frame of an ongoing scroll is judged against the frame before the take. A
    /// report's delta, as UMA uploads histogram deltas while the recorders keep their state
    /// (base/metrics/histogram_snapshot_manager.cc, cc/metrics/scroll_jank_dropped_frame_tracker.cc).
    public mutating func takeCounts() -> InputLatencyLedger {
        var counts = InputLatencyLedger()
        counts.rows = rows
        counts.slotsReceived = slotsReceived
        counts.slotsWithoutFrameUpdate = slotsWithoutFrameUpdate
        counts.slotsDropped = slotsDropped
        counts.scrollJank = scrollJank.takeCounts()
        counts.interactions = interactions.takeCounts()
        rows = [:]
        slotsReceived = 0
        slotsWithoutFrameUpdate = 0
        slotsDropped = 0
        return counts
    }

    /// Adds the counts of `other` (rows, slot counters, scroll jank counts and histograms, closed
    /// interactions); its scroll and interactions in progress and drop baseline are not counts and
    /// are left out.
    public mutating func add(_ other: InputLatencyLedger) {
        for (key, row) in other.rows { rows[key, default: Row()].add(row) }
        slotsReceived &+= other.slotsReceived
        slotsWithoutFrameUpdate &+= other.slotsWithoutFrameUpdate
        slotsDropped &+= other.slotsDropped
        scrollJank.addCounts(other.scrollJank)
        interactions.addCounts(other.interactions)
    }

    /// Counts `count` slots lost before the ledger saw them.
    public mutating func noteDropped(_ count: UInt64) {
        slotsDropped &+= count
    }

    /// Folds `batch` in.
    public mutating func fold(_ batch: InputLatencyBatch) {
        // A smaller total is a new producer whose counters started again at 0.
        let total = batch.droppedTotal
        noteDropped(total >= lastDroppedTotal ? total - lastDroppedTotal : total)
        lastDroppedTotal = total
        for slot in batch.slots { fold(slot, vsyncNanos: batch.vsyncNanos, display: batch.display) }
    }

    private mutating func fold(_ slot: InputLatencySlot, vsyncNanos: UInt64, display: InputDisplayClass) {
        slotsReceived &+= 1
        // Scroll begins seldom update a frame, so the scroll's life is read before the drop below;
        // only a slot that updated a frame adds a scroll frame.
        if slot.entrypoint == .person { trackScroll(slot, vsyncNanos: vsyncNanos) }
        // A key or click that changed nothing on screen is still an interaction (INP counts it).
        interactions.record(slot)
        guard slot.causedFrameUpdate || slot.kind.isKey else {
            slotsWithoutFrameUpdate &+= 1
            return
        }
        let key = Key(kind: slot.kind, target: slot.target, entrypoint: slot.entrypoint, presentationSource: slot.presentationSource,
                      display: display)
        Self.count(slot, in: &rows[key, default: Row()])
    }

    private static func count(_ slot: InputLatencySlot, in row: inout Row) {
        row.count &+= 1
        if let total = slot.totalNanos { row.total.record(nanos: total) }
        for stage in pipelineStages where stage != .generated {
            guard let delta = delta(of: stage, in: slot) else { continue }
            row.stages[Int(stage.rawValue)].record(nanos: delta)
        }
    }

    /// The time from the stage `slot` reached just before `stage` to `stage`, or nil when `stage`
    /// was skipped or is ``InputStage/lastGenerated``: ``interval(to:in:)`` without its start.
    static func delta(of stage: InputStage, in slot: InputLatencySlot) -> UInt64? {
        interval(to: stage, in: slot)?.nanos
    }

    /// The stage `slot` reached just before `stage` and the time from it to `stage`, or nil when
    /// `stage` was skipped, is ``InputStage/lastGenerated`` or has no stage before it. Stages are
    /// ordered by time, not by declaration: a terminal key's echo comes back before its frame is
    /// submitted. Equal times keep declaration order. The stage histograms and
    /// ``InputLatencySlot/dominantStage`` both read it.
    static func interval(to stage: InputStage, in slot: InputLatencySlot) -> (from: InputStage, nanos: UInt64)? {
        let time = slot[stage]
        guard time != 0, stage != .lastGenerated else { return nil }
        var previous: (stage: InputStage, time: UInt64)?
        for other in pipelineStages where other != stage {
            let otherTime = slot[other]
            guard otherTime != 0 else { continue }
            let before = otherTime < time || (otherTime == time && other.rawValue < stage.rawValue)
            if before, otherTime >= previous?.time ?? 0 { previous = (other, otherTime) }
        }
        guard let previous else { return nil }
        return (previous.stage, time - previous.time)
    }

    // MARK: scroll jank

    private mutating func trackScroll(_ slot: InputLatencySlot, vsyncNanos: UInt64) {
        switch slot.kind {
        case .scrollBegin:
            flushScrollFrame()
            scrollJank.scrollStarted()
        case .scrollFirstUpdate:
            flushScrollFrame()
            scrollJank.scrollStarted()
            gatherScrollFrame(slot, vsyncNanos: vsyncNanos)
        case .scrollUpdate, .scrollMomentum:
            gatherScrollFrame(slot, vsyncNanos: vsyncNanos)
        case .keyPress, .keyRelease, .flags, .mousePress, .mouseRelease, .pointerMove, .drag, .scrollEnd, .magnify:
            return
        }
    }

    private mutating func gatherScrollFrame(_ slot: InputLatencySlot, vsyncNanos: UInt64) {
        // cc drops an event that caused no frame update before its frame reporter.
        guard slot.causedFrameUpdate, slot.presented != 0, slot.generated != 0 else { return }
        let last = max(slot.lastGenerated, slot.generated)
        if var frame = pendingFrame, frame.presented == slot.presented {
            frame.first = min(frame.first, slot.generated)
            frame.last = max(frame.last, last)
            pendingFrame = frame
            return
        }
        flushScrollFrame()
        pendingFrame = ScrollFrame(first: slot.generated, last: last, presented: slot.presented, vsyncNanos: vsyncNanos)
    }

    private mutating func flushScrollFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        scrollJank.framePresented(firstGenerated: frame.first, lastGenerated: frame.last, presented: frame.presented, vsyncNanos: frame.vsyncNanos)
    }

    // MARK: report

    /// The ledger as report fields; the most frequent row first (then by key).
    public var snapshot: InputLatencySnapshot {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            let lhsOrder = Self.order(lhs.key)
            let rhsOrder = Self.order(rhs.key)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.key.display.refreshHz, lhs.key.display.vrr ? 1 : 0) < (rhs.key.display.refreshHz, rhs.key.display.vrr ? 1 : 0)
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
                    display: key.display,
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
            ),
            interactions: InputLatencySnapshot.Interactions(interactions.summary)
        )
    }

    private static func order(_ key: Key) -> UInt32 {
        UInt32(key.kind.rawValue) << 24 | UInt32(key.target.rawValue) << 16
            | UInt32(key.entrypoint.rawValue) << 8 | UInt32(key.presentationSource.rawValue)
    }
}
