@testable import CmuxNextInputCore
import Foundation
import Testing

/// The input latency ledger: rows per kind x target x entrypoint x presentation
/// source whose bucket counts add up, skipped stages that add no sample, Chrome's drop of non-key
/// inputs with no frame update, lost slots counted, and cc's scroll jank formula
/// (cc/metrics/scroll_jank_dropped_frame_tracker.cc), with a frame split across batches and a
/// scroll update that changed nothing. Run:
/// `swift test --filter InputLatencyLedgerTests`.
struct InputLatencyLedgerTests {
    private static let ms: UInt64 = 1_000_000
    /// One refresh at 60 Hz.
    private static let vsync: UInt64 = 16_666_667

    private static func slot(
        _ kind: InputEventKind,
        target: InputTarget = .terminal,
        entrypoint: InputEntrypoint = .person,
        source: InputPresentationSource = .estimatedVsync,
        updated: Bool = true,
        generated: UInt64,
        _ stages: [InputStage: UInt64] = [:]
    ) -> InputLatencySlot {
        var slot = InputLatencySlot(kind: kind, target: target, entrypoint: entrypoint, presentationSource: source,
                                    causedFrameUpdate: updated)
        slot.generated = generated
        for (stage, nanos) in stages { slot[stage] = nanos }
        return slot
    }

    // MARK: histograms

    @Test func bucketCountsAddUpToEachRowsCount() throws {
        var slots: [InputLatencySlot] = []
        for index in 0..<300 {
            let generated = 1_000 * Self.ms + UInt64(index) * Self.ms
            let total = UInt64(index % 40) * Self.ms / 2 + 1
            let kind: InputEventKind = index.isMultiple(of: 3) ? .keyPress : .mousePress
            let target: InputTarget = index.isMultiple(of: 2) ? .terminal : .sidebar
            slots.append(Self.slot(kind, target: target, generated: generated,
                                   [.dispatchStart: generated + total / 3, .presented: generated + total]))
        }
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: Array(slots[..<150]), vsyncNanos: Self.vsync))
        ledger.fold(InputLatencyBatch(slots: Array(slots[150...]), vsyncNanos: Self.vsync))

        #expect(ledger.slotsReceived == 300)
        #expect(ledger.rows.count == 4, "two kinds times two targets")
        #expect(ledger.rows.values.reduce(0) { $0 + $1.count } == 300)
        for row in ledger.rows.values {
            #expect(row.total.count == row.count)
            #expect(row.total.buckets.total == row.total.count, "the buckets of a row count every value once")
            for stage in InputStage.allCases {
                #expect(row[stage].buckets.total == row[stage].count)
            }
            #expect(row[.dispatchStart].count == row.count)
            #expect(row[.presented].count == row.count)
        }
        let report = ledger.snapshot
        for row in report.rows {
            #expect(row.total.buckets.reduce(0, +) == row.count)
            #expect(row.total.buckets.count == InputLatencyBuckets.bucketCount)
        }
        #expect(report.rows.map(\.count) == report.rows.map(\.count).sorted(by: >), "the most frequent row first")
    }

    @Test func percentilesComeFromTheBucketsAndNeverPassTheMax() throws {
        var histogram = InputLatencyHistogram()
        #expect(histogram.percentileNanos(0.5) == nil)
        for _ in 0..<90 { histogram.record(nanos: 3 * Self.ms) }
        for _ in 0..<9 { histogram.record(nanos: 15 * Self.ms) }
        histogram.record(nanos: 300 * Self.ms)
        #expect(histogram.count == 100)
        #expect(histogram.percentileNanos(0.5) == 4 * Self.ms, "3 ms falls in the (2, 4] bucket")
        #expect(histogram.percentileNanos(0.95) == 16_700_000, "15 ms falls in the (12, 16.7] bucket")
        #expect(histogram.percentileNanos(0.99) == 16_700_000)
        #expect(histogram.percentileNanos(1) == 300 * Self.ms, "the overflow bucket reports the largest value")
        var small = InputLatencyHistogram()
        small.record(nanos: 5 * Self.ms)
        #expect(small.percentileNanos(0.5) == 5 * Self.ms, "a percentile never passes the largest value")
        let snapshot = histogram.snapshot
        #expect(snapshot.p50Milliseconds == 4)
        #expect(snapshot.maxMilliseconds == 300)
    }

    // MARK: stages

    @Test func skippedStagesAddNoSample() throws {
        let generated = 50 * Self.ms
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.mousePress, target: .layout, generated: generated,
                      [.dispatchStart: generated + 2 * Self.ms, .presented: generated + 9 * Self.ms]),
        ], vsyncNanos: Self.vsync))
        let row = try #require(ledger.rows.values.first)
        #expect(row.count == 1)
        #expect(row[.dispatchStart].count == 1)
        #expect(row[.dispatchStart].maxNanos == 2 * Self.ms)
        #expect(row[.presented].maxNanos == 7 * Self.ms, "the time since the stage before, not since generated")
        #expect(row.total.maxNanos == 9 * Self.ms)
        for stage in InputStage.allCases where stage != .dispatchStart && stage != .presented {
            #expect(row[stage].count == 0, "stage \(stage) was skipped and must add no sample")
        }
        let reported = try #require(ledger.snapshot.rows.first)
        #expect(reported.stages.map(\.stage) == ["dispatchStart", "presented"])
    }

    @Test func stageDeltasFollowTimeNotDeclarationOrder() throws {
        // A terminal key: the echo comes back before the terminal frame is submitted and committed.
        let generated = 10 * Self.ms
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.keyPress, generated: generated, [
                .dispatchEnd: generated + 1 * Self.ms,
                .daemonReceived: generated + 2 * Self.ms,
                .echoSent: generated + 4 * Self.ms,
                .contentSubmitted: generated + 5 * Self.ms,
                .mainCommit: generated + 6 * Self.ms,
                .presented: generated + 10 * Self.ms,
            ]),
        ], vsyncNanos: Self.vsync))
        let row = try #require(ledger.rows.values.first)
        #expect(row[.dispatchEnd].maxNanos == 1 * Self.ms)
        #expect(row[.daemonReceived].maxNanos == 1 * Self.ms)
        #expect(row[.echoSent].maxNanos == 2 * Self.ms)
        #expect(row[.contentSubmitted].maxNanos == 1 * Self.ms, "the time since the echo, not since dispatch")
        #expect(row[.mainCommit].maxNanos == 1 * Self.ms)
        #expect(row[.presented].maxNanos == 4 * Self.ms)
        let sum = InputStage.allCases.reduce(UInt64(0)) { $0 + row[$1].sumNanos }
        #expect(sum == row.total.sumNanos, "the stage deltas add up to the total")
    }

    @Test func aCoalescedSlotsStagesAreMeasuredFromItsOldestEvent() throws {
        // Five pointer events over 20 ms reach main 2 ms after the newest: arrivedMain is 22 ms.
        let generated = 100 * Self.ms
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.pointerMove, target: .layout, generated: generated, [
                .lastGenerated: generated + 20 * Self.ms,
                .arrivedMain: generated + 22 * Self.ms,
                .dispatchEnd: generated + 23 * Self.ms,
                .presented: generated + 30 * Self.ms,
            ]),
        ], vsyncNanos: Self.vsync))
        let row = try #require(ledger.rows.values.first)
        #expect(row[.arrivedMain].maxNanos == 22 * Self.ms, "Chrome's GenerationToBrowserMain runs from the oldest event")
        #expect(row[.lastGenerated].count == 0, "the newest event's time is not a stage")
        #expect(row[.dispatchEnd].maxNanos == 1 * Self.ms)
        #expect(row[.presented].maxNanos == 7 * Self.ms)
        let sum = InputStage.allCases.reduce(UInt64(0)) { $0 + row[$1].sumNanos }
        #expect(sum == row.total.sumNanos, "the stage deltas add up to the total")
        let reported = try #require(ledger.snapshot.rows.first)
        #expect(!reported.stages.map(\.stage).contains("lastGenerated"))
    }

    // MARK: drops

    @Test func nonKeySlotsWithoutAFrameUpdateAreDroppedAndKeysKept() throws {
        let generated = 5 * Self.ms
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.pointerMove, target: .layout, updated: false, generated: generated, [.presented: generated + Self.ms]),
            Self.slot(.mousePress, target: .layout, updated: false, generated: generated),
            Self.slot(.keyPress, updated: false, generated: generated, [.dispatchEnd: generated + Self.ms]),
            Self.slot(.keyRelease, updated: false, generated: generated, [.dispatchEnd: generated + Self.ms]),
            Self.slot(.pointerMove, target: .layout, updated: true, generated: generated, [.presented: generated + 3 * Self.ms]),
        ], vsyncNanos: Self.vsync))
        #expect(ledger.slotsReceived == 5)
        #expect(ledger.slotsWithoutFrameUpdate == 2)
        #expect(ledger.rows.count == 3)
        let press = try #require(ledger.rows[InputLatencyLedger.Key(kind: .keyPress, target: .terminal, entrypoint: .person, presentationSource: .estimatedVsync)])
        #expect(press.count == 1, "a key that changed nothing on screen is still counted")
        #expect(press.total.count == 0, "with no presented frame it has no total")
        #expect(press[.dispatchEnd].count == 1)
        let move = try #require(ledger.rows[InputLatencyLedger.Key(kind: .pointerMove, target: .layout, entrypoint: .person, presentationSource: .estimatedVsync)])
        #expect(move.count == 1, "only the move that updated a frame")
        #expect(ledger.snapshot.slotsWithoutFrameUpdate == 2)
    }

    @Test func rowsSplitByEntrypointAndPresentationSource() {
        let generated = 5 * Self.ms
        let stages: [InputStage: UInt64] = [.presented: generated + Self.ms]
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.keyPress, generated: generated, stages),
            Self.slot(.keyPress, entrypoint: .automation, generated: generated, stages),
            Self.slot(.keyPress, source: .metalPresented, generated: generated, stages),
            Self.slot(.keyPress, generated: generated, stages),
        ], vsyncNanos: Self.vsync))
        #expect(ledger.rows.count == 3)
        #expect(ledger.rows[InputLatencyLedger.Key(kind: .keyPress, target: .terminal, entrypoint: .person, presentationSource: .estimatedVsync)]?.count == 2)
    }

    @Test func slotsLostBeforeTheLedgerAreCountedOnce() throws {
        let ring = InputLatencyRing(capacity: 4)
        var ledger = InputLatencyLedger()
        func appendAndFold(_ count: Int) -> InputLatencyBatch {
            for index in 0..<count {
                ring.append(Self.slot(.keyPress, generated: UInt64(index + 1) * Self.ms, [.presented: UInt64(index + 2) * Self.ms]))
            }
            let slots = ring.takeBatch()
            let batch = InputLatencyBatch(slots: slots, vsyncNanos: Self.vsync, droppedTotal: ring.droppedCount)
            ledger.fold(batch)
            return batch
        }
        let first = appendAndFold(10)
        #expect(first.slots.count == 4)
        #expect(first.droppedTotal == 6)
        // The ring's counter is cumulative: the second batch carries 6 + 3 and adds only its 3.
        let second = appendAndFold(7)
        #expect(second.droppedTotal == 9)
        let third = appendAndFold(2)
        #expect(third.droppedTotal == 9, "a batch with no new drop adds none")
        ledger.noteDropped(3)
        #expect(ledger.slotsReceived == 10)
        #expect(ledger.slotsDropped == 12, "the ring's nine and a dropped hand-off batch's three")
        let report = ledger.snapshot
        #expect(report.slotsDropped == 12)
        #expect(report.slotsReceived == 10)
    }

    // MARK: scroll jank

    /// One frame presented at `presented` for an input generated at `generated`.
    private static func frame(_ tracker: inout ScrollJankTracker, generated: UInt64, presented: UInt64) {
        tracker.framePresented(firstGenerated: generated, lastGenerated: generated, presented: presented, vsyncNanos: vsync)
    }

    @Test func aGapOfOnePointFourVsyncsIsNotJanky() {
        var tracker = ScrollJankTracker()
        tracker.scrollStarted()
        let start: UInt64 = 1_000 * Self.ms
        Self.frame(&tracker, generated: start - Self.ms, presented: start)
        Self.frame(&tracker, generated: start - Self.ms, presented: start + Self.vsync * 14 / 10)
        #expect(tracker.presentedFrames == 1, "the scroll's first frame is not counted")
        #expect(tracker.delayedFrames == 0)
        #expect(tracker.currentScroll?.missedVsyncsSum == 0)
    }

    @Test func aGapOfTwoPointSixVsyncsMissesTwo() {
        var tracker = ScrollJankTracker()
        tracker.scrollStarted()
        let start: UInt64 = 1_000 * Self.ms
        Self.frame(&tracker, generated: start - Self.ms, presented: start)
        Self.frame(&tracker, generated: start - Self.ms, presented: start + Self.vsync * 26 / 10)
        #expect(tracker.delayedFrames == 1)
        #expect(tracker.currentScroll?.missedVsyncsSum == 2)
        #expect(tracker.currentScroll?.missedVsyncsMax == 2)
        // 1.6 vsyncs: janky, one missed.
        let previous = start + Self.vsync * 26 / 10
        Self.frame(&tracker, generated: previous - Self.ms, presented: previous + Self.vsync * 16 / 10)
        #expect(tracker.delayedFrames == 2)
        #expect(tracker.currentScroll?.missedVsyncsSum == 3)
        #expect(tracker.currentScroll?.missedVsyncsMax == 2)
    }

    @Test func aLateFrameIsNotJankyWhenItsInputCameAfterThePreviousFrame() {
        var tracker = ScrollJankTracker()
        tracker.scrollStarted()
        let start: UInt64 = 1_000 * Self.ms
        Self.frame(&tracker, generated: start - Self.ms, presented: start)
        Self.frame(&tracker, generated: start + 3 * Self.vsync, presented: start + 4 * Self.vsync)
        #expect(tracker.presentedFrames == 1)
        #expect(tracker.delayedFrames == 0, "no input was waiting during the gap")
    }

    @Test func framesChromeSkipsAreSkipped() {
        var tracker = ScrollJankTracker()
        tracker.scrollStarted()
        let start: UInt64 = 1_000 * Self.ms
        Self.frame(&tracker, generated: start - Self.ms, presented: start)
        Self.frame(&tracker, generated: start - 2 * Self.ms, presented: start - Self.ms)
        tracker.framePresented(firstGenerated: start, lastGenerated: start - 1, presented: start + Self.vsync, vsyncNanos: Self.vsync)
        Self.frame(&tracker, generated: start + 2 * Self.vsync, presented: start + Self.vsync)
        tracker.framePresented(firstGenerated: start, lastGenerated: start, presented: start + 3 * Self.vsync, vsyncNanos: 0)
        #expect(tracker.presentedFrames == 0)
        #expect(tracker.skippedFrames == 5, "first frame, out of order, inputs reversed, presented before its input, no vsync")
    }

    @Test func theFixedWindowEmitsEverySixtyFourFrames() throws {
        var tracker = ScrollJankTracker()
        tracker.scrollStarted()
        var presented: UInt64 = 1_000 * Self.ms
        Self.frame(&tracker, generated: presented - Self.ms, presented: presented)
        for index in 0..<ScrollJankTracker.fixedWindowFrames {
            // Every eighth frame misses one vsync (a two-vsync gap) with its input waiting.
            let gap = index.isMultiple(of: 8) ? 2 * Self.vsync : Self.vsync
            let generated = presented - Self.ms
            presented += gap
            Self.frame(&tracker, generated: generated, presented: presented)
        }
        #expect(tracker.presentedFrames == 64)
        #expect(tracker.delayedFrames == 8)
        let histograms = tracker.histograms
        #expect(histograms.values[.delayedFramesPercentageFixedWindow] == [12: 1], "8 of 64 frames is 12 percent (integer)")
        #expect(histograms.values[.missedVsyncsSumFixedWindow] == [8: 1])
        #expect(histograms.values[.missedVsyncsMaxFixedWindow] == [1: 1])
        #expect(tracker.currentWindow == ScrollJankTracker.JankData(), "the window starts over")
        #expect(histograms.count(.delayedFramesPercentagePerScroll) == 0, "the scroll is still going")
    }

    @Test func perScrollHistogramsComeFromTheLedgersScrollSlots() throws {
        var slots: [InputLatencySlot] = []
        var presented: UInt64 = 1_000 * Self.ms
        func scroll(frames: Int, jankyAt: Set<Int>) {
            // The begin changes no frame: the ledger drops its row but still starts the scroll.
            slots.append(Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: presented - 2 * Self.ms))
            for index in 0..<frames {
                let generated = presented - Self.ms
                presented += jankyAt.contains(index) ? 3 * Self.vsync : Self.vsync
                let kind: InputEventKind = index == 0 ? .scrollFirstUpdate : .scrollUpdate
                slots.append(Self.slot(kind, target: .sidebar, generated: generated, [.presented: presented]))
                if index == 3 {
                    // A second update shown in the same frame folds into it.
                    slots.append(Self.slot(.scrollUpdate, target: .sidebar, generated: generated + 1, [.presented: presented]))
                }
            }
            slots.append(Self.slot(.scrollEnd, target: .sidebar, updated: false, generated: presented))
            presented += 100 * Self.ms
        }
        scroll(frames: 11, jankyAt: [5])
        scroll(frames: 5, jankyAt: [])
        // Synthetic scrolls are left out of the jank counts.
        slots.append(Self.slot(.scrollFirstUpdate, target: .sidebar, entrypoint: .automation, generated: presented,
                               [.presented: presented + 10 * Self.vsync]))
        slots.append(Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: presented + 11 * Self.vsync))

        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: slots, vsyncNanos: Self.vsync))
        let jank = ledger.scrollJank
        #expect(jank.presentedFrames == 14, "each scroll's first frame is not counted")
        #expect(jank.delayedFrames == 1)
        #expect(jank.histograms.values[.delayedFramesPercentagePerScroll] == [10: 1, 0: 1], "1 of 10, then 0 of 4")
        #expect(jank.histograms.values[.missedVsyncsSumPerScroll] == [2: 1, 0: 1])
        #expect(jank.histograms.values[.missedVsyncsMaxPerScroll] == [2: 1, 0: 1])
        #expect(ledger.slotsWithoutFrameUpdate == 5, "both scrolls' begins and ends, and the last begin")
        let report = ledger.snapshot.scrollJank
        #expect(report.delayedFrames == 1)
        let perScroll = try #require(report.histograms["Event.ScrollJank.DelayedFramesPercentage.PerScroll"])
        #expect(perScroll.samples == [.init(value: 0, count: 1), .init(value: 10, count: 1)])
    }

    @Test func oneFrameSplitAcrossTwoBatchesIsOneFrame() throws {
        // Frame A at 1000 ms, then frame B 2.6 vsyncs later shows two updates, one per batch. The
        // second batch's update is the older one and was waiting before A: B is janky.
        let start: UInt64 = 1_000 * Self.ms
        let late = start + Self.vsync * 26 / 10
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: start - 3 * Self.ms),
            Self.slot(.scrollFirstUpdate, target: .sidebar, generated: start - 2 * Self.ms, [.presented: start]),
            Self.slot(.scrollUpdate, target: .sidebar, generated: start + Self.ms, [.presented: late]),
        ], vsyncNanos: Self.vsync))
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.scrollUpdate, target: .sidebar, generated: start - Self.ms, [.presented: late]),
        ], vsyncNanos: Self.vsync))
        #expect(ledger.scrollJank.presentedFrames == 0, "the frame still gathering is counted on a later fold")
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: late + 100 * Self.ms),
        ], vsyncNanos: Self.vsync))
        let jank = ledger.scrollJank
        #expect(jank.presentedFrames == 1, "both halves are one frame")
        #expect(jank.skippedFrames == 1, "only the scroll's first frame is skipped")
        #expect(jank.delayedFrames == 1, "judged by the older input from the second batch")
        #expect(jank.histograms.values[.missedVsyncsSumPerScroll] == [2: 1])
    }

    @Test func aScrollUpdateThatChangedNoFrameAddsNoScrollFrame() throws {
        // Scrolling against the end: the updates change nothing, yet their slots close with a
        // presented time. Only the frames that changed count.
        let start: UInt64 = 1_000 * Self.ms
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.scrollFirstUpdate, target: .sidebar, generated: start - Self.ms, [.presented: start]),
            Self.slot(.scrollUpdate, target: .sidebar, updated: false, generated: start, [.presented: start + Self.vsync]),
            Self.slot(.scrollUpdate, target: .sidebar, updated: false, generated: start + Self.vsync, [.presented: start + 2 * Self.vsync]),
            Self.slot(.scrollUpdate, target: .sidebar, generated: start + 2 * Self.vsync, [.presented: start + 3 * Self.vsync]),
            Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: start + 100 * Self.ms),
        ], vsyncNanos: Self.vsync))
        let jank = ledger.scrollJank
        #expect(jank.presentedFrames == 1, "the two no-update slots add no frame")
        #expect(jank.skippedFrames == 1)
        #expect(jank.delayedFrames == 0, "the input came after the previous frame")
        #expect(ledger.slotsWithoutFrameUpdate == 3)
    }

    @Test func aScrollThatSpansATakeIsMeasuredAsOneScroll() throws {
        // A report takes deltas (UMA's histogram_snapshot_manager.cc); cc's
        // ScrollJankDroppedFrameTracker keeps its state, so the frame after the take is judged
        // against the frame before it, not skipped as a scroll's first frame.
        let start: UInt64 = 1_000 * Self.ms
        let ms = Self.ms
        func update(_ kind: InputEventKind = .scrollUpdate, at vsyncs: UInt64, inputBefore: UInt64? = nil) -> InputLatencySlot {
            let presented = start + vsyncs * Self.vsync
            return Self.slot(kind, target: .sidebar, generated: presented - (inputBefore ?? ms), [.presented: presented])
        }
        let first = InputLatencyBatch(slots: [
            Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: start - 3 * Self.ms),
            update(.scrollFirstUpdate, at: 0), update(at: 1), update(at: 2),
        ], vsyncNanos: Self.vsync)
        // The frame at vsync 6 shows an input from before the frame at vsync 3: janky, two missed.
        let second = InputLatencyBatch(slots: [
            update(at: 3), update(at: 6, inputBefore: 3 * Self.vsync + Self.ms),
            Self.slot(.scrollBegin, target: .sidebar, updated: false, generated: start + 100 * Self.vsync),
        ], vsyncNanos: Self.vsync)

        var whole = InputLatencyLedger()
        whole.fold(first)
        whole.fold(second)

        var ledger = InputLatencyLedger()
        ledger.fold(first)
        var taken = ledger.takeCounts()
        #expect(taken.scrollJank.presentedFrames == 1, "frame 2 is still gathering")
        #expect(taken.scrollJank.skippedFrames == 1)
        #expect(ledger.snapshot.rows.isEmpty, "the take moved the rows out")
        ledger.fold(second)
        let rest = ledger.takeCounts()
        #expect(rest.scrollJank.skippedFrames == 0, "the frame after the take is not a first frame")
        #expect(rest.scrollJank.presentedFrames == 3)
        #expect(rest.scrollJank.delayedFrames == 1)
        #expect(rest.scrollJank.histograms.values[.delayedFramesPercentagePerScroll] == [25: 1],
                "the scroll's PerScroll histogram counts all four frames")
        taken.add(rest)
        #expect(taken.snapshot == whole.snapshot, "two takes add up to no take")
    }

    @Test func rowsSplitByDisplay() throws {
        let generated = 5 * Self.ms
        let key = Self.slot(.keyPress, generated: generated, [.presented: generated + 7 * Self.ms])
        let proMotion = InputDisplayClass(refreshHz: 120, vrr: true)
        let external = InputDisplayClass(refreshHz: 60, vrr: false)
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [key], vsyncNanos: 8_333_333, display: proMotion))
        ledger.fold(InputLatencyBatch(slots: [key, key], vsyncNanos: Self.vsync, display: external))
        let rows = ledger.snapshot.rows
        #expect(rows.map(\.display) == [external, proMotion])
        #expect(rows.map(\.count) == [2, 1])
        let data = try JSONEncoder().encode(ledger.snapshot)
        #expect(String(decoding: data, as: UTF8.self).contains("\"refresh_hz\":120"))
    }

    // MARK: report

    @Test func theReportEncodesWithItsFieldNames() throws {
        var ledger = InputLatencyLedger()
        let generated = 5 * Self.ms
        ledger.fold(InputLatencyBatch(slots: [
            Self.slot(.keyPress, generated: generated, [.presented: generated + 7 * Self.ms]),
        ], vsyncNanos: Self.vsync, droppedTotal: 2))
        let report = ledger.snapshot
        let data = try JSONEncoder().encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["slots_dropped"] as? Int == 2)
        #expect(object["slots_received"] as? Int == 1)
        #expect((object["bucket_edges_ms"] as? [Double])?.count == InputLatencyBuckets.edgesNanos.count)
        let row = try #require((object["rows"] as? [[String: Any]])?.first)
        #expect(row["kind"] as? String == "keyPress")
        #expect(row["presentation_source"] as? String == "estimatedVsync")
        #expect((row["total"] as? [String: Any])?["max_ms"] as? Double == 7)
        #expect(try JSONDecoder().decode(InputLatencySnapshot.self, from: data) == report)
    }
}
