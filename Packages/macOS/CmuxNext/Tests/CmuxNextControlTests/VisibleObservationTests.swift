import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// VisibleObservation (plans/cmux-next/chrome-parity/p06-scheduler.md, task 025): tracking only
/// while the node is visible, one apply per flush, the flush class from the highest cause of the
/// changes to what it read, and the input-response pass's capped person flush.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VisibleObservationTests {
    @Test func aHiddenObservationReadsNothingForAHundredChanges() {
        let harness = Harness(own: .hidden)
        let watch = harness.watch()
        #expect(harness.reads == 1, "the first value is read and applied in the caller's turn")
        #expect(harness.applied == [0])
        for value in 1...100 { harness.model.value = value }
        harness.frame()
        harness.frame()
        #expect(harness.reads == 1, "a hidden view read \(harness.reads - 1) times")
        #expect(watch.trackingCallbacks == 0, "a hidden observation armed a tracking")
        harness.stop(watch)
    }

    @Test func fiveChangesBeforeAFrameGiveOneApply() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        for value in 1...5 { harness.model.value = value }
        // Below person, each change re-arms the tracking (one read) so a higher cause can still raise it.
        #expect(harness.reads == 6)
        #expect(harness.applied == [0], "a change applies nothing in its own turn")
        harness.frame()
        #expect(harness.reads == 7, "the flush reads once")
        #expect(harness.applied == [0, 5])
        harness.frame()
        #expect(harness.reads == 7, "a frame with no change reads nothing")
        harness.stop(watch)
    }

    @Test func hideThenShowReadsOnceAndAppliesTheLatestValue() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.node.set(.hidden)
        for value in 1...10 { harness.model.value = value }
        harness.frame()
        #expect(harness.reads == 1)
        harness.node.set(.visible)
        #expect(harness.reads == 2, "show reads once, in the show turn")
        #expect(harness.applied == [0, 10])
        harness.model.value = 11
        harness.frame()
        #expect(harness.applied == [0, 10, 11], "tracking is armed again after show")
        harness.stop(watch)
    }

    @Test func anOccludedNodeStopsTrackingLikeAHiddenOne() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.node.set(.occluded)
        harness.model.value = 1
        harness.frame()
        #expect(harness.reads == 1)
        harness.node.set(.visible)
        #expect(harness.applied == [0, 1])
        harness.stop(watch)
    }

    @Test func afterHideTheRegistrarHoldsNoTracking() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.node.set(.hidden)
        // The cancel signal fired the armed tracking once; it is stale and does nothing.
        let afterHide = watch.trackingCallbacks
        #expect(afterHide == 1)
        for value in 1...10 { harness.model.value = value }
        #expect(watch.trackingCallbacks == afterHide, "a tracking stayed registered after hide")
        harness.frame()
        #expect(harness.reads == 1)
        harness.stop(watch)
    }

    @Test func aDirtyObservationDropsItsReArmedTrackingOnHide() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.model.value = 1
        harness.node.set(.hidden)
        let afterHide = watch.trackingCallbacks
        for value in 2...10 { harness.model.value = value }
        #expect(watch.trackingCallbacks == afterHide, "the re-armed tracking stayed registered after hide")
        harness.frame()
        #expect(harness.applied == [0], "a hidden view applied a dropped flush")
        harness.stop(watch)
    }

    /// Every read, apply and arm lands in `debug.observations` under the owner,
    /// so a bench sees what one change cost (without the recording the ledger reads 0 here).
    @Test func theLedgerCountsArmsReadsAppliesAndShowRereads() throws {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        func counts() throws -> ObservationLedger.Entry {
            try #require(harness.work.observations.snapshot(matching: "test.watch").first)
        }
        let start = try counts()
        #expect(start.armed == 1 && start.arms == 1)
        #expect(start.evaluations == 0 && start.applies == 0, "the first read and apply are the init's, not a change's")

        for value in 1...5 { harness.model.value = value }
        harness.frame()
        let changed = try counts()
        // reads == 7: the init's, one re-arm per change below person, and the flush's.
        #expect(changed.evaluations == 6 && changed.applies == 1)
        #expect(changed.armed == 1, "the flush's tracking is the only one armed")

        harness.node.set(.hidden)
        #expect(try counts().armed == 0, "a hidden observation is disarmed")
        harness.model.value = 6
        harness.node.set(.visible)
        let shown = try counts()
        #expect(shown.showRereads == 1 && shown.armed == 1)
        #expect(shown.applies == 2, "the show applied the changed value")

        harness.stop(watch)
        #expect(try counts().armed == 0, "a cancelled observation is disarmed")
    }

    /// Observations of one owner share the scheduler's cached handle: the ledger's lock is taken for the name's
    /// first instance only, and every instance counts under the one owner.
    @Test func observationsOfOneOwnerShareOneCachedLedgerOwner() throws {
        let harness = Harness(own: .visible)
        let first = harness.watch(), second = harness.watch()
        #expect(harness.work.observationOwner("test.watch") === harness.work.observationOwner("test.watch"))
        #expect(harness.work.observationOwner("test.watch") === harness.work.observations.owner("test.watch"))
        let entries = harness.work.observations.snapshot(matching: "test.watch")
        #expect(entries.count == 1 && entries.first?.armed == 2)
        harness.stop(first, second)
    }

    @Test func anAutomationChangeFlushesInTheAutomationClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        // While a key is pending, automation yields for one frame and runs the next.
        harness.input.pending = true
        harness.frame()
        #expect(harness.applied == [0], "an automation flush ran ahead of a pending key")
        harness.frame()
        #expect(harness.applied == [0, 1])
        #expect(classes == [nil, .automation])
        harness.stop(watch)
    }

    @Test func programAndFrontendChangesFlushInTheVisibleClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.model.value = 1
        harness.frame()
        harness.work.causes.withCause(.frontend) { harness.model.value = 2 }
        harness.frame()
        #expect(classes == [nil, .visible, .visible])
        harness.stop(watch)
    }

    @Test func automationThenFrontendOnTheSamePropertyFlushesInTheVisibleClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        harness.work.causes.withCause(.frontend) { harness.model.value = 2 }
        // An open input response holds automation; the app's own frontend update must not wait for it.
        harness.work.noteDiscreteInput(expectsFrame: true)
        harness.frame()
        #expect(harness.applied == [0, 2])
        #expect(classes == [nil, .visible])
        harness.stop(watch)
    }

    @Test func automationThenPersonOnTheSamePropertyFlushesAsPerson() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        // The first tracking fired on the automation change; the re-armed one sees the person's.
        harness.work.causes.withCause(.person) { harness.model.value = 2 }
        let reads = harness.reads
        #expect(harness.work.causes.flushPersonCaused() == 1)
        #expect(harness.applied == [0, 2], "the person's value applies in the input-response pass")
        #expect(classes == [nil, .frame])
        harness.frame()
        #expect(harness.reads == reads + 1, "the pass flushed it: the frame reads nothing more")
        #expect(harness.applied == [0, 2])
        harness.stop(watch)
    }

    @Test func aPersonChangeOfAnotherPropertyLeavesAnAutomationFlushAsAutomation() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        let reads = harness.reads
        harness.work.causes.withCause(.person) { harness.model.other = 1 }
        #expect(harness.reads == reads, "a change of a property it did not read touched the observation")
        #expect(harness.work.causes.flushPersonCaused() == 0)
        #expect(harness.work.causes.personPendingCount == 0)
        harness.input.pending = true
        harness.frame()
        #expect(harness.applied == [0], "the automation flush ran ahead of a pending key")
        harness.frame()
        #expect(classes == [nil, .automation])
        harness.stop(watch)
    }

    /// The rest of a person's action: a person flush the pass did not reach
    /// runs as userBlocking, not visible.
    @Test func aPersonFlushOutsideThePassRunsInTheUserBlockingClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.work.causes.withCause(.person) { harness.model.value = 1 }
        #expect(harness.work.causes.personPendingCount == 1)
        harness.frame()
        #expect(harness.applied == [0, 1])
        #expect(classes == [nil, .userBlocking])
        #expect(harness.work.causes.flushPersonCaused() == 0, "the userBlocking flush left the pass nothing")
        harness.stop(watch)
    }

    @Test func anAutomationOnlyChangeIsNotFlushedByThePass() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        #expect(harness.work.causes.flushPersonCaused() == 0)
        #expect(harness.applied == [0])
        harness.frame()
        #expect(harness.applied == [0, 1])
        harness.stop(watch)
    }

    /// 500 rows an agent made dirty, then one person change of each row's property: the pass stops
    /// at the visible + automation shares (3.5 ms), and the rest follow in the userBlocking class,
    /// capped at the same shares a frame.
    @Test func thePassStopsAtItsCapAndTheUserBlockingClassAppliesTheRest() {
        let harness = Harness(own: .visible)
        var applied = 0
        let watches = (0..<500).map { _ in
            harness.watch {
                applied += 1
                harness.clock.advance(ms: 0.1)
            }
        }
        applied = 0
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        harness.work.causes.withCause(.person) { harness.model.value = 2 }
        #expect(harness.work.causes.flushPersonCaused() == 35)
        #expect(applied == 35)
        var frames = 0
        while applied < 500, frames < 100 {
            let before = applied
            harness.frame()
            frames += 1
            #expect(applied - before <= 41, "one frame applied \(applied - before) flushes past the 4 ms of scheduled work")
        }
        #expect(applied == 500)
        harness.stop(watches)
    }

    /// 1000 rows an agent made dirty and one person change elsewhere: the person's turn reads,
    /// promotes and applies none of them, and the frames drain them in the automation share.
    @Test func aThousandAutomationDirtyRowsCostAnUnrelatedPersonChangeNothing() {
        let harness = Harness(own: .visible)
        var classes: Set<MainWorkClass?> = []
        var applied = 0
        let watches = (0..<1000).map { _ in
            harness.watch {
                applied += 1
                classes.insert(harness.work.budget.board.running?.workClass)
                harness.clock.advance(ms: 0.1)
            }
        }
        applied = 0
        classes = []
        harness.work.causes.withCause(.automation) { harness.model.value = 1 }
        harness.frame()
        let firstFrame = applied
        #expect(firstFrame > 0 && firstFrame <= 41)
        let reads = harness.reads
        harness.work.causes.withCause(.person) { harness.model.other = 1 }
        #expect(harness.reads == reads)
        #expect(harness.work.causes.flushPersonCaused() == 0)
        #expect(applied == firstFrame, "the person's turn applied agent rows")
        var frames = 0
        while applied < 1000, frames < 200 {
            harness.frame()
            frames += 1
        }
        #expect(applied == 1000)
        #expect(classes == [.automation])
        harness.stop(watches)
    }

    @Test func anEqualValueIsNotAppliedAgain() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.model.value = 1
        harness.model.value = 0
        let reads = harness.reads
        harness.frame()
        #expect(harness.reads == reads + 1)
        #expect(harness.applied == [0])
        harness.stop(watch)
    }

    @Test func cancelStopsEveryLaterApply() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.model.value = 1
        watch.cancel()
        harness.frame()
        harness.node.set(.hidden)
        harness.node.set(.visible)
        #expect(harness.applied == [0])
        #expect(watch.isCancelled)
        harness.stop(watch)
    }

    @Test func aFrozenNodeHoldsTheFlushAndThePassSkipsIt() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.node.freeze()
        harness.work.causes.withCause(.person) { harness.model.value = 1 }
        #expect(harness.work.causes.flushPersonCaused() == 0)
        harness.frame()
        #expect(harness.applied == [0], "a frozen node's flush ran")
        harness.node.unfreeze()
        harness.frame()
        #expect(harness.applied == [0, 1])
        harness.stop(watch)
    }

    /// Released while armed and clean: the deinit's cancel signal fires the tracking at once, so
    /// the registrar drops it and no later change reaches it.
    @Test func aTokenReleasedWhileArmedDropsItsTracking() {
        let harness = Harness(own: .visible)
        var watch: VisibleObservation<Int>? = harness.watch()
        _ = watch
        watch = nil
        #expect(harness.work.causes.releasedTrackingFires == 1, "the release left the tracking armed")
        for value in 1...10 { harness.model.value = value }
        #expect(harness.work.causes.releasedTrackingFires == 1, "a released token's tracking stayed registered")
        harness.frame()
        #expect(harness.reads == 1)
        #expect(harness.applied == [0])
        harness.stop()
    }

    @Test func aDirtyTokenReleasedAppliesNothing() {
        let harness = Harness(own: .visible)
        var watch: VisibleObservation<Int>? = harness.watch()
        harness.work.causes.withCause(.person) { harness.model.value = 1 }
        _ = watch
        watch = nil
        #expect(harness.work.causes.personPendingCount == 0)
        #expect(harness.work.causes.flushPersonCaused() == 0)
        for value in 2...10 { harness.model.value = value }
        harness.frame()
        #expect(harness.applied == [0])
        harness.stop()
    }

    /// Released off the main thread: the deinit's signal write reaches main one hop later.
    @Test func aTokenReleasedOffTheMainThreadDropsItsTrackingOneHopLater() async {
        let harness = Harness(own: .visible)
        let retained = Unmanaged.passRetained(harness.watch())
        await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                retained.release()
                // Queued behind the deinit's hop on the main queue.
                MainDelivery().run { released.resume() }
            }
        }
        #expect(harness.work.causes.releasedTrackingFires == 1, "the off-main release left the tracking armed")
        harness.model.value = 1
        #expect(harness.work.causes.releasedTrackingFires == 1)
        harness.stop()
    }

    @Test func causeScopesNestAndRestore() {
        let harness = Harness(own: .visible)
        let causes = harness.work.causes
        #expect(causes.currentCause == .program)
        causes.withCause(.automation) {
            #expect(causes.currentCause == .automation)
            causes.withCause(.person) { #expect(causes.currentCause == .person) }
            #expect(causes.currentCause == .automation)
        }
        #expect(causes.currentCause == .program)
        harness.stop()
    }
}

/// The observed model.
@MainActor @Observable
private final class ObservedModel {
    var value = 0
    var other = 0
}

/// A scheduler on a fake link kept up by a frame client (so posts wait for hand-fired frames), a
/// root node and a model, with read and apply counters.
@MainActor
private final class Harness {
    let model = ObservedModel()
    let input: HarnessInputPending
    let clock: HarnessClock
    let node: VisibilityNode
    let work: MainWorkScheduler
    private let keeper: FrameClient
    private(set) var reads = 0
    private(set) var applied: [Int] = []
    private var timestamp: Double = 0

    init(own: Visibility) {
        let input = HarnessInputPending(), clock = HarnessClock()
        self.input = input
        self.clock = clock
        node = VisibilityNode(root: "window", own: own)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in HarnessFrameLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Observes `model.value`; `onApply` runs inside each apply.
    func watch(onApply: @escaping @MainActor () -> Void = {}) -> VisibleObservation<Int> {
        VisibleObservation(node, owner: "test.watch", on: work) { [self] in
            reads += 1
            return model.value
        } apply: { [self] value in
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

    /// Cancels `watches` and stops the frames.
    func stop(_ watches: VisibleObservation<Int>...) { stop(watches) }

    func stop(_ watches: [VisibleObservation<Int>]) {
        for watch in watches { watch.cancel() }
        keeper.deactivate()
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class HarnessClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

@MainActor
private final class HarnessInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class HarnessFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
