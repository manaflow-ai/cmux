import CmuxNextCompat
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// FrameObservation (plans/cmux-next/chrome-parity/p04-input.md, task 025): one scheduled apply per
/// dirty period, never a task per change; one apply per frame for `.visible`; `.automation` with no
/// display link; `.sameTurn` on the next run loop pass or at once for a reader in the same turn;
/// both budgeted kinds yield to pending input; a person-caused change applies in the input-response
/// pass before any frame; an equal value applies nothing.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameObservationTests {
    @Test func aHundredChangesScheduleOneDeliveryAndApplyOnceInTheNextFrame() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        #expect(rig.reads == 1, "init reads once in the caller's turn")
        #expect(rig.applied.isEmpty, "init does not call onChange")
        for value in 1...100 { rig.model.value = value }
        #expect(watch.deliveriesScheduled == 1, "one delivery for 100 changes, not one task per change")
        #expect(watch.trackingCallbacks == 100 && rig.reads == 101,
                "a program change re-arms with one read, so a person's later change can raise the cause")
        #expect(rig.applied.isEmpty, "a change applies nothing in its own turn")
        rig.frame()
        #expect(rig.applied == [100])
        #expect(rig.reads == 102, "the apply reads once")
        #expect(watch.value == 100)
        rig.frame()
        #expect(rig.applied == [100], "a frame with no change applies nothing")
        rig.stop(watch)
    }

    @Test(arguments: [Kind.visible, Kind.automation, Kind.sameTurn])
    func aPersonCausedChangeAppliesInTheInputResponsePassBeforeAnyFrame(_ kind: Kind) {
        let rig = ObservationRig()
        var classes: [MainWorkClass?] = []
        let watch = rig.watch(rig.delivery(kind)) { classes.append(rig.work.budget.board.running?.workClass) }
        rig.input.pending = true
        rig.work.causes.withCause(.person) {
            for value in 1...100 { rig.model.value = value }
        }
        #expect(watch.trackingCallbacks == 1 && rig.reads == 1, "a person-caused dirty period re-armed")
        #expect(rig.work.causes.personPendingCount == 1)
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(rig.applied == [100], "the person's change waited for a frame")
        #expect(classes == [.frame], "it applied outside the input-response pass")
        #expect(rig.reads == 2)
        rig.input.pending = false
        rig.frame()
        rig.frame()
        #expect(rig.applied == [100], "the scheduled apply ran again after the pass")
        #expect(rig.reads == 2)
        #expect(watch.deliveriesScheduled == 1)
        rig.stop(watch)
    }

    @Test func aPersonChangeAfterAProgramChangeRaisesTheApplyIntoThePass() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.model.value = 1
        #expect(rig.work.causes.flushPersonCaused() == 0, "a program change applied in the pass")
        rig.work.causes.withCause(.person) { rig.model.value = 2 }
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(rig.applied == [2])
        rig.frame()
        #expect(rig.applied == [2])
        #expect(watch.deliveriesScheduled == 1)
        rig.stop(watch)
    }

    @Test func aHiddenNodeLeavesAPersonChangeToTheShow() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.node.set(.hidden)
        rig.work.causes.withCause(.person) { rig.model.value = 1 }
        #expect(rig.work.causes.flushPersonCaused() == 0, "the pass applied to a hidden window")
        #expect(rig.applied.isEmpty)
        rig.node.set(.visible)
        #expect(rig.applied == [1])
        rig.stop(watch)
    }

    @Test func aSameTurnReaderSeesTheChangeInItsOwnTurn() {
        let rig = ObservationRig(makeLink: false)
        let watch = rig.watch(.sameTurn("the key handler reads the cache in its own turn"))
        rig.model.value = 7
        #expect(watch.value == 0, "value applied a change before anyone asked")
        #expect(watch.currentValue == 7, "a reader in the change's turn read the old value")
        #expect(rig.applied == [7], "flushIfDirty did not run onChange, so a cache it writes is stale")
        let reads = rig.reads
        watch.flushIfDirty()
        #expect(rig.reads == reads, "flushIfDirty read with nothing pending")
        rig.drainRunLoopBlocks()
        #expect(rig.applied == [7], "the run loop block applied again")
        rig.stop(watch)
    }

    @Test func aValueSetAndRestoredBeforeTheFrameAppliesNothing() throws {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.model.value = 1
        rig.model.value = 0
        rig.frame()
        #expect(rig.applied.isEmpty, "onChange ran for the value it already had")
        let counts = try #require(rig.work.observations.snapshot(matching: "test.frameObservation").first)
        #expect(counts.applies == 0)
        #expect(counts.evaluations >= 1)
        rig.model.value = 3
        rig.frame()
        #expect(rig.applied == [3])
        rig.stop(watch)
    }

    @Test func eachFrameAppliesAtMostOnceAndTheChangeLandsInTheFrameAfterIt() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.model.value = 1
        rig.model.value = 2
        rig.frame()
        rig.model.value = 3
        #expect(rig.applied == [2], "a change after the frame waits for the next one")
        rig.model.value = 4
        rig.frame()
        #expect(rig.applied == [2, 4])
        #expect(watch.deliveriesScheduled == 2)
        rig.stop(watch)
    }

    @Test func aChangeToSomethingNotReadSchedulesNothing() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.model.unread = 1
        rig.frame()
        #expect(watch.trackingCallbacks == 0)
        #expect(watch.deliveriesScheduled == 0)
        #expect(rig.applied.isEmpty)
        rig.stop(watch)
    }

    @Test func aHiddenNodeTracksNothingAndAppliesOnceWhenItShows() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.node.set(.hidden)
        for value in 1...10 { rig.model.value = value }
        rig.frame()
        rig.frame()
        #expect(rig.applied.isEmpty, "a hidden window applied")
        #expect(rig.reads == 1, "a hidden window read")
        #expect(watch.trackingCallbacks == 1, "a tracking stayed registered after hide (the hide's own fire only)")
        rig.node.set(.visible)
        #expect(rig.applied == [10], "the show reads once and applies the latest value")
        rig.frame()
        #expect(rig.applied == [10])
        #expect(rig.reads == 2)
        rig.stop(watch)
    }

    @Test func aNodeFreeVisibleObservationAppliesInTheFrameAfterTheChange() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(nil))
        rig.model.value = 5
        #expect(rig.applied.isEmpty)
        rig.frame()
        #expect(rig.applied == [5])
        rig.stop(watch)
    }

    @Test(arguments: [Kind.visible, Kind.automation])
    func pendingInputHoldsTheApplyLikeAVisibleBatch(_ kind: Kind) {
        let rig = ObservationRig()
        let watch = rig.watch(rig.delivery(kind))
        rig.input.pending = true
        rig.model.value = 1
        rig.frame()
        #expect(rig.applied.isEmpty, "the apply ran ahead of the person's pending input")
        rig.input.pending = false
        rig.frame()
        #expect(rig.applied == [1], "the input cleared: it applies")
        rig.stop(watch)
    }

    @Test func automationAppliesWithNoDisplayLink() {
        let rig = ObservationRig(makeLink: false)
        let watch = rig.watch(.automation)
        for value in 1...50 { rig.model.value = value }
        #expect(watch.deliveriesScheduled == 1)
        #expect(rig.applied.isEmpty, "never inline")
        rig.spinMainRunLoop { !rig.applied.isEmpty }
        #expect(rig.applied == [50])
        #expect(!rig.work.frames.hasLink, "automation needed a display link")
        #expect(rig.work.frames.frames == 0, "it waited for a frame")
        rig.model.value = 51
        rig.spinMainRunLoop { rig.applied.count == 2 }
        #expect(rig.applied == [50, 51], "it re-arms after each apply")
        rig.stop(watch)
    }

    @Test func automationAppliesInTheAutomationClass() {
        let rig = ObservationRig()
        var classes: [MainWorkClass?] = []
        let watch = rig.watch(.automation) { classes.append(rig.work.budget.board.running?.workClass) }
        rig.model.value = 1
        rig.frame()
        #expect(classes == [.automation])
        rig.stop(watch)
    }

    @Test func sameTurnAppliesOnTheNextRunLoopPassWithoutAFrame() {
        let rig = ObservationRig(makeLink: false)
        let watch = rig.watch(.sameTurn("the key handler reads the cache in its own turn"))
        for value in 1...20 { rig.model.value = value }
        #expect(watch.deliveriesScheduled == 1)
        #expect(rig.applied.isEmpty, "never inline: the will-set has not stored the value yet")
        rig.spinMainRunLoop { !rig.applied.isEmpty }
        #expect(rig.applied == [20])
        #expect(rig.work.frames.frames == 0)
        rig.stop(watch)
    }

    @Test func cancelStopsEveryLaterReadAndApply() {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        rig.model.value = 1
        watch.cancel()
        let reads = rig.reads
        rig.frame()
        rig.model.value = 2
        rig.frame()
        #expect(rig.applied.isEmpty, "a cancelled observation applied")
        #expect(rig.reads == reads, "a cancelled observation read")
        #expect(watch.isCancelled)
        rig.stop(watch)
    }

    @Test func theLedgerCountsOneArmedTrackingAndOneApplyPerFrame() throws {
        let rig = ObservationRig()
        let watch = rig.watch(.visible(rig.node))
        func counts() throws -> ObservationLedger.Entry {
            try #require(rig.work.observations.snapshot(matching: "test.frameObservation").first)
        }
        #expect(try counts().armed == 1)
        for value in 1...5 { rig.model.value = value }
        #expect(try counts().armed == 1, "the re-armed tracking replaced the fired one")
        rig.work.causes.withCause(.person) { rig.model.value = 6 }
        #expect(try counts().armed == 0, "the fired tracking is gone until the apply")
        rig.frame()
        let applied = try counts()
        #expect(applied.armed == 1 && applied.applies == 1)
        #expect(applied.evaluations == 6, "five re-arm reads and the apply's")
        watch.cancel()
        #expect(try counts().armed == 0, "a cancelled observation is disarmed")
        rig.stop(watch)
    }

    enum Kind: CustomTestStringConvertible {
        case visible, automation, sameTurn
        var testDescription: String {
            switch self {
            case .visible: "visible"
            case .automation: "automation"
            case .sameTurn: "sameTurn"
            }
        }
    }
}

@MainActor @Observable
private final class ObservedModel {
    var value = 0
    var unread = 0
}

/// A scheduler on a fake link (or none), a hand-moved budget clock and a manual stall clock.
@MainActor
private final class ObservationRig {
    let model = ObservedModel()
    let input: RigInputPending
    let node = VisibilityNode(root: "window", own: .visible)
    let work: MainWorkScheduler
    private let clock: RigClock
    private var timestamp: Double = 0
    private var keeper: FrameClient?
    private(set) var reads = 0
    private(set) var applied: [Int] = []
    private var drained = false

    /// - Parameter makeLink: false: the link factory returns nil (an occluded window, a headless run).
    init(makeLink: Bool = true) {
        let input = RigInputPending(), clock = RigClock()
        self.input = input
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                         clock: ManualClock()) { _ -> (any FrameLink)? in
            guard makeLink else { return nil }
            return RigFrameLink()
        }
        guard makeLink else { return }
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        self.keeper = keeper
    }

    func delivery(_ kind: FrameObservationTests.Kind) -> FrameObservationDelivery {
        switch kind {
        case .visible: .visible(node)
        case .automation: .automation
        case .sameTurn: .sameTurn("the test reads in the change's turn")
        }
    }

    func watch(_ delivery: FrameObservationDelivery, onApply: @escaping @MainActor () -> Void = {}) -> FrameObservation<Int> {
        FrameObservation(owner: "test.frameObservation", delivery: delivery, on: work) { [unowned self] in
            reads += 1
            return model.value
        } onChange: { [unowned self] value in
            onApply()
            applied.append(value)
        }
    }

    /// One display frame, 17 ms after the last one.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Spins the main run loop until every block queued before the call ran (they run in order).
    func drainRunLoopBlocks() {
        drained = false
        MainRunLoopBlock.perform { [weak self] in self?.drained = true }
        spinMainRunLoop { drained }
    }

    func stop(_ watch: FrameObservation<Int>) {
        watch.cancel()
        keeper?.deactivate()
    }
}

/// The budget's clock (`CLOCK_UPTIME_RAW` nanoseconds), moved by the test.
@MainActor
private final class RigClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: UInt64) { now += ms * 1_000_000 }
}

@MainActor
private final class RigInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class RigFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
