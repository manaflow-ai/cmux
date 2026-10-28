@testable import CmuxNextInputCore
import Testing

/// cmux's INP: events pair into interactions as Chromium's
/// responsiveness_metrics.cc pairs them, an interaction is its longest event, and the session's
/// high percentile ignores one interaction for each 50 from a fixed list of the 11 worst
/// (responsiveness_metrics_normalization.cc); the ledger folds them from its slots and a report
/// takes them as deltas. Run: `swift test --filter InteractionLatencyTests`.
struct InteractionLatencyTests {
    private static let ms: UInt64 = 1_000_000

    /// One key press and release of `keyCode`, the press taking `down` ms and the release `up` ms.
    private static func key(_ interactions: inout InteractionLatency, _ keyCode: UInt16 = 0, down: UInt64, up: UInt64,
                            target: InputTarget = .terminal) {
        interactions.record(kind: .keyPress, target: target, entrypoint: .person, keyCode: keyCode, latencyNanos: down * ms)
        interactions.record(kind: .keyRelease, target: target, entrypoint: .person, keyCode: keyCode, latencyNanos: up * ms)
    }

    private static func pointer(_ interactions: inout InteractionLatency, _ kind: InputEventKind, _ latencyMs: UInt64,
                                target: InputTarget = .sidebar) {
        interactions.record(kind: kind, target: target, entrypoint: .person, keyCode: 0, latencyNanos: latencyMs * ms)
    }

    // MARK: no allocation

    @Test func theTrackerIsAPlainValueSoRecordingNeverAllocates() {
        // No reference and no array anywhere in it: every record is in-place stores into a value.
        #expect(_isPOD(InteractionLatency.self))
        #expect(_isPOD(InteractionLatency.Summary.self))
        #expect(MemoryLayout<InteractionLatency.WorstList.Storage>.size == InteractionLatency.keptWorst * 8)

        var interactions = InteractionLatency()
        for index in 0 ..< 10_000 {
            Self.key(&interactions, UInt16(index % 50), down: UInt64(index % 37), up: 1)
        }
        #expect(interactions.summary.count == 10_000)
        #expect(interactions.summary.worstNanos == 36 * Self.ms)
    }

    // MARK: the high percentile

    @Test func oneHundredTwentyInteractionsWithTwoOutliersReportTheThirdWorst() {
        var interactions = InteractionLatency()
        for index in 0 ..< 117 {
            Self.key(&interactions, down: 4 + UInt64(index % 10), up: 1)
        }
        Self.key(&interactions, down: 300, up: 2)
        Self.key(&interactions, down: 200, up: 2)
        Self.key(&interactions, down: 40, up: 2)

        let summary = interactions.summary
        #expect(summary.count == 120)
        #expect(summary.worstNanos == 300 * Self.ms)
        #expect(summary.highPercentileNanos == 40 * Self.ms, "120 / 50 = 2 ignored: the third-worst")
        #expect(summary.highPercentileMs == 40)
        #expect(summary.kindOfWorst == .key)
        #expect(summary.targetOfWorst == .terminal)
    }

    @Test func underFiftyInteractionsTheHighPercentileIsTheWorst() {
        var interactions = InteractionLatency()
        for latency: UInt64 in [3, 90, 7, 12] {
            Self.key(&interactions, down: latency, up: 1)
        }
        #expect(interactions.summary.count == 4)
        #expect(interactions.summary.highPercentileNanos == 90 * Self.ms)
    }

    @Test func pastFiveHundredFortyNineInteractionsTheIndexStopsAtTheEleventhWorst() {
        var interactions = InteractionLatency()
        for latency in 1 ... UInt64(600) {
            Self.key(&interactions, down: latency, up: 0)
        }
        // 600 / 50 = 12 would ignore 12; the fixed list keeps 11, so the 11th worst (590).
        #expect(interactions.summary.highPercentileNanos == 590 * Self.ms)
        #expect(interactions.summary.worstNanos == 600 * Self.ms)
    }

    @Test func noInteractionReportsZero() {
        let summary = InteractionLatency().summary
        #expect(summary.count == 0)
        #expect(summary.worstNanos == 0)
        #expect(summary.highPercentileNanos == 0)
        #expect(summary.kindOfWorst == nil)
        #expect(summary.targetOfWorst == nil)
    }

    // MARK: pairing keys

    @Test func aKeyInteractionIsAsLongAsItsLongestEvent() {
        var interactions = InteractionLatency()
        Self.key(&interactions, 12, down: 5, up: 22)
        #expect(interactions.summary.count == 1)
        #expect(interactions.summary.worstNanos == 22 * Self.ms)
    }

    @Test func aKeyWithNoReleaseClosesAtTheNextKey() {
        var interactions = InteractionLatency()
        interactions.record(kind: .keyPress, target: .terminal, entrypoint: .person, keyCode: 1, latencyNanos: 30 * Self.ms)
        #expect(interactions.summary.count == 0, "an open key is not counted yet")
        interactions.record(kind: .keyPress, target: .palette, entrypoint: .person, keyCode: 2, latencyNanos: 3 * Self.ms)
        #expect(interactions.summary.count == 1)
        #expect(interactions.summary.worstNanos == 30 * Self.ms)
        #expect(interactions.summary.targetOfWorst == .terminal)

        // Key 1's late release has no open press of its own: dropped. Key 2's closes key 2.
        interactions.record(kind: .keyRelease, target: .terminal, entrypoint: .person, keyCode: 1, latencyNanos: 90 * Self.ms)
        #expect(interactions.summary.count == 1)
        interactions.record(kind: .keyRelease, target: .palette, entrypoint: .person, keyCode: 2, latencyNanos: 4 * Self.ms)
        #expect(interactions.summary.count == 2)
        #expect(interactions.summary.worstNanos == 30 * Self.ms)
    }

    @Test func autoRepeatPressesAreEachTheirOwnInteraction() {
        var interactions = InteractionLatency()
        for _ in 0 ..< 3 {
            interactions.record(kind: .keyPress, target: .terminal, entrypoint: .person, keyCode: 7, latencyNanos: Self.ms)
        }
        interactions.record(kind: .keyRelease, target: .terminal, entrypoint: .person, keyCode: 7, latencyNanos: Self.ms)
        #expect(interactions.summary.count == 3)
    }

    // MARK: pairing the pointer

    @Test func aClickIsATapAndAPressDragReleaseIsOneDragWhoseMovesAddNoLatency() {
        var interactions = InteractionLatency()
        Self.pointer(&interactions, .mousePress, 6)
        Self.pointer(&interactions, .mouseRelease, 9)
        #expect(interactions.summary.count == 1)
        #expect(interactions.summary.kindOfWorst == .tap)
        #expect(interactions.summary.worstNanos == 9 * Self.ms)

        Self.pointer(&interactions, .mousePress, 8, target: .layout)
        for _ in 0 ..< 50 { Self.pointer(&interactions, .drag, 400, target: .layout) }
        Self.pointer(&interactions, .mouseRelease, 14, target: .layout)
        #expect(interactions.summary.count == 2, "the drag is one interaction")
        #expect(interactions.summary.worstNanos == 14 * Self.ms, "drag moves are not interaction events")
        #expect(interactions.summary.kindOfWorst == .drag)
        #expect(interactions.summary.targetOfWorst == .layout)
    }

    @Test func aPressWithNoReleaseClosesAtTheNextPressAndAStrayReleaseIsDropped() {
        var interactions = InteractionLatency()
        Self.pointer(&interactions, .mouseRelease, 50)
        #expect(interactions.summary.count == 0)
        Self.pointer(&interactions, .mousePress, 20)
        Self.pointer(&interactions, .mousePress, 5)
        #expect(interactions.summary.count == 1)
        #expect(interactions.summary.worstNanos == 20 * Self.ms)
    }

    @Test func keysAndThePointerPairIndependently() {
        var interactions = InteractionLatency()
        interactions.record(kind: .keyPress, target: .terminal, entrypoint: .person, keyCode: 3, latencyNanos: 2 * Self.ms)
        Self.pointer(&interactions, .mousePress, 4)
        interactions.record(kind: .keyRelease, target: .terminal, entrypoint: .person, keyCode: 3, latencyNanos: 2 * Self.ms)
        Self.pointer(&interactions, .mouseRelease, 4)
        #expect(interactions.summary.count == 2)
    }

    // MARK: what is not an interaction

    @Test func scrollsMovesFlagsAndAutomationAreNotInteractions() {
        // A drag with no press open, too: it starts nothing.
        var interactions = InteractionLatency()
        for kind: InputEventKind in [.flags, .pointerMove, .scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum,
                                     .scrollEnd, .magnify, .drag] {
            interactions.record(kind: kind, target: .terminal, entrypoint: .person, keyCode: 0, latencyNanos: 500 * Self.ms)
        }
        interactions.record(kind: .keyPress, target: .terminal, entrypoint: .automation, keyCode: 0, latencyNanos: 900 * Self.ms)
        interactions.record(kind: .keyRelease, target: .terminal, entrypoint: .automation, keyCode: 0, latencyNanos: 900 * Self.ms)
        #expect(interactions.summary.count == 0)
        #expect(interactions.summary.worstNanos == 0)
    }

    // MARK: slots and report periods

    @Test func aSlotIsMeasuredToItsPresentedFrameOrItsCommitWhenNothingWasPresented() {
        var interactions = InteractionLatency()
        var presented = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, keyCode: 5)
        presented[.generated] = 100 * Self.ms
        presented[.mainCommit] = 103 * Self.ms
        presented[.presented] = 111 * Self.ms
        interactions.record(presented)
        var release = InputLatencySlot(kind: .keyRelease, target: .terminal, entrypoint: .person, keyCode: 5)
        release[.generated] = 120 * Self.ms
        release[.dispatchEnd] = 121 * Self.ms
        interactions.record(release)
        #expect(interactions.summary.count == 1, "the release of key 5 closes key 5")
        #expect(interactions.summary.worstNanos == 11 * Self.ms)

        var unchanged = InputLatencySlot(kind: .keyPress, target: .textView, entrypoint: .person, keyCode: 6)
        unchanged[.generated] = 200 * Self.ms
        unchanged[.dispatchEnd] = 213 * Self.ms
        interactions.record(unchanged)
        var other = InputLatencySlot(kind: .keyRelease, target: .textView, entrypoint: .person, keyCode: 7)
        other[.generated] = 214 * Self.ms
        other[.dispatchEnd] = 215 * Self.ms
        interactions.record(other)
        #expect(interactions.summary.count == 1, "a release of another key code does not close key 6")
        interactions.record(presented)
        #expect(interactions.summary.count == 2)
        #expect(interactions.summary.worstNanos == 13 * Self.ms, "no frame: measured to the dispatch end")
        #expect(interactions.summary.targetOfWorst == .textView)
    }

    @Test func takeCountsMovesTheClosedOnesOutAndKeepsAnOpenOneForTheNextReport() {
        var interactions = InteractionLatency()
        Self.key(&interactions, 1, down: 7, up: 1)
        Self.pointer(&interactions, .mousePress, 30)
        Self.pointer(&interactions, .drag, 3)

        var taken = interactions.takeCounts()
        #expect(taken.summary.count == 1, "the drag is still open")
        #expect(taken.summary.kindOfWorst == .key)
        #expect(interactions.summary.count == 0)

        Self.pointer(&interactions, .mouseRelease, 4)
        let rest = interactions.takeCounts()
        #expect(rest.summary.count == 1, "the drag spanning the take counts once, where it closed")
        #expect(rest.summary.kindOfWorst == .drag)
        #expect(rest.summary.worstNanos == 30 * Self.ms)

        taken.addCounts(rest)
        #expect(taken.summary.count == 2)
        #expect(taken.summary.worstNanos == 30 * Self.ms)
        #expect(taken.summary.kindOfWorst == .drag)
        #expect(taken.summary.targetOfWorst == .sidebar)
    }

    @Test func addingTwoPeriodsGivesTheSameHighPercentileAsOne() {
        // 120 interactions split 70 / 50 across two takes: the merged 11-worst list is exact.
        var whole = InteractionLatency()
        var split = InteractionLatency()
        var first = InteractionLatency()
        for index in 0 ..< 120 {
            let latency = UInt64((index * 37) % 97) + 1
            Self.key(&whole, down: latency, up: 0)
            Self.key(&split, down: latency, up: 0)
            if index == 69 { first = split.takeCounts() }
        }
        first.addCounts(split.takeCounts())
        #expect(first.summary == whole.summary)
        #expect(first.summary.count == 120)

        var empty = InteractionLatency()
        empty.addCounts(InteractionLatency())
        #expect(empty.summary.count == 0 && empty.summary.kindOfWorst == nil)
    }

    // MARK: the ledger and the slot table

    @Test func theLedgerFoldsInteractionsFromEveryKeyAndClickEvenWithoutAFrameUpdate() {
        func slot(_ kind: InputEventKind, keyCode: UInt16 = 0, at generatedMs: UInt64, tookMs: UInt64,
                  entrypoint: InputEntrypoint = .person) -> InputLatencySlot {
            var slot = InputLatencySlot(kind: kind, target: .terminal, entrypoint: entrypoint, keyCode: keyCode)
            slot.generated = generatedMs * Self.ms
            slot.dispatchEnd = (generatedMs + tookMs) * Self.ms
            return slot
        }
        var ledger = InputLatencyLedger()
        ledger.fold(InputLatencyBatch(slots: [
            slot(.keyPress, keyCode: 4, at: 10, tookMs: 25),
            slot(.keyRelease, keyCode: 4, at: 60, tookMs: 2),
            slot(.mousePress, at: 100, tookMs: 3),
            slot(.mouseRelease, at: 140, tookMs: 5),
            slot(.keyPress, keyCode: 9, at: 200, tookMs: 90, entrypoint: .automation),
            slot(.keyRelease, keyCode: 9, at: 300, tookMs: 90, entrypoint: .automation),
        ], vsyncNanos: 16_666_667))
        #expect(ledger.slotsWithoutFrameUpdate == 2, "the clicks updated no frame")
        #expect(ledger.interactions.summary.count == 2, "the key and the click; automation is not counted")
        #expect(ledger.interactions.summary.worstNanos == 25 * Self.ms)

        let snapshot = ledger.snapshot.interactions
        #expect(snapshot == InputLatencySnapshot.Interactions(count: 2, worstMilliseconds: 25, highPercentileMilliseconds: 25,
                                                              kindOfWorst: "key", targetOfWorst: "terminal"))

        let taken = ledger.takeCounts()
        #expect(taken.interactions.summary.count == 2)
        #expect(ledger.interactions.summary.count == 0, "the take moved them out")
        ledger.reset()
        #expect(ledger.snapshot.interactions == InputLatencySnapshot.Interactions())
    }

    @Test func theSlotTableCarriesTheKeyCodeToTheClosedSlot() throws {
        // One entry, so the click reuses the key's entry: it must not inherit the key code.
        let table = InputLatencySlotTable(capacity: 1)
        let press = try #require(table.begin(kind: .keyPress, target: .terminal, entrypoint: .person, generated: 5, keyCode: 53))
        #expect(table.close(press)?.keyCode == 53)
        let click = try #require(table.begin(kind: .mousePress, target: .sidebar, entrypoint: .person, generated: 6))
        #expect(table.close(click)?.keyCode == 0)
    }

    @Test func kindsHaveClosedWireNames() {
        #expect(InteractionLatency.Kind.allCases.map(\.wireName) == ["key", "tap", "drag"])
    }
}
