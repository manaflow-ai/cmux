import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// VisibleObservation (plans/cmux-next/chrome-parity/p06-scheduler.md, task 025): tracking only
/// while the node is visible, one read per flush, the flush class from the change's cause, and
/// person over automation through the person-cause epoch.
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
        watch.cancel()
    }

    @Test func fiveChangesBeforeAFrameGiveOneReadAndOneApply() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        for value in 1...5 { harness.model.value = value }
        #expect(harness.reads == 1, "a change reads nothing in its own turn")
        harness.frame()
        #expect(harness.reads == 2)
        #expect(harness.applied == [0, 5])
        harness.frame()
        #expect(harness.reads == 2, "a frame with no change reads nothing")
        watch.cancel()
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
        watch.cancel()
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
        watch.cancel()
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
        watch.cancel()
    }

    @Test func anAutomationChangeFlushesInTheAutomationClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.causes.withCause(.automation) { harness.model.value = 1 }
        // While a key is pending, automation yields for one frame and runs the next.
        harness.input.pending = true
        harness.frame()
        #expect(harness.applied == [0], "an automation flush ran ahead of a pending key")
        harness.frame()
        #expect(harness.applied == [0, 1])
        #expect(classes == [nil, .automation])
        watch.cancel()
    }

    @Test func programAndFrontendChangesFlushInTheVisibleClass() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.model.value = 1
        harness.frame()
        harness.causes.withCause(.frontend) { harness.model.value = 2 }
        harness.frame()
        #expect(classes == [nil, .visible, .visible])
        watch.cancel()
    }

    @Test func automationThenPersonOnTheSamePropertyFlushesAsPerson() {
        let harness = Harness(own: .visible)
        var classes: [MainWorkClass?] = []
        let watch = harness.watch { classes.append(harness.work.budget.board.running?.workClass) }
        harness.causes.withCause(.automation) { harness.model.value = 1 }
        // The tracking fired on the automation change; the person's change of the same property
        // does not fire it again, but it moves the epoch.
        harness.causes.withCause(.person) { harness.model.value = 2 }
        #expect(harness.causes.flushPersonCaused() == 1)
        #expect(harness.applied == [0, 2], "the person's value applies in the input-response pass")
        #expect(classes == [nil, .frame])
        harness.frame()
        #expect(harness.reads == 2, "the pass flushed it: the frame reads nothing more")
        watch.cancel()
    }

    @Test func aPersonChangeOutsideThePassRunsInTheNextFrameAheadOfPendingInput() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.causes.withCause(.person) { harness.model.value = 1 }
        harness.input.pending = true
        harness.frame()
        #expect(harness.applied == [0, 1], "a person flush waited behind the budget")
        watch.cancel()
    }

    @Test func anAutomationOnlyChangeIsNotFlushedByThePass() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.causes.withCause(.automation) { harness.model.value = 1 }
        #expect(harness.causes.flushPersonCaused() == 0)
        #expect(harness.applied == [0])
        harness.frame()
        #expect(harness.applied == [0, 1])
        watch.cancel()
    }

    @Test func anEqualValueIsNotAppliedAgain() {
        let harness = Harness(own: .visible)
        let watch = harness.watch()
        harness.model.value = 1
        harness.model.value = 0
        harness.frame()
        #expect(harness.reads == 2)
        #expect(harness.applied == [0])
        watch.cancel()
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
    }

    @Test func aReleasedTokenAppliesNothingAndLeavesNothingDirty() {
        let harness = Harness(own: .visible)
        var watch: VisibleObservation<Int>? = harness.watch()
        harness.model.value = 1
        #expect(harness.causes.dirtyCount == 1)
        watch = nil
        #expect(watch == nil)
        #expect(harness.causes.dirtyCount == 0, "a released observation stayed dirty")
        for value in 2...10 { harness.model.value = value }
        harness.frame()
        harness.node.set(.hidden)
        harness.node.set(.visible)
        #expect(harness.reads == 1)
        #expect(harness.applied == [0])
    }

    @Test func causeScopesNestAndRestore() {
        let causes = ObservationCauses()
        #expect(causes.currentCause == .program)
        causes.withCause(.automation) {
            #expect(causes.currentCause == .automation)
            causes.withCause(.person) { #expect(causes.currentCause == .person) }
            #expect(causes.currentCause == .automation)
        }
        #expect(causes.currentCause == .program)
        #expect(causes.personCauseEpoch == 1)
    }
}

/// The observed model.
@MainActor @Observable
private final class ObservedModel {
    var value = 0
}

/// A scheduler on a fake link, a visible root node and a model, with read and apply counters.
@MainActor
private final class Harness {
    let model = ObservedModel()
    let causes = ObservationCauses()
    let input: HarnessInputPending
    let clock: HarnessClock
    let node: VisibilityNode
    let work: MainWorkScheduler
    private(set) var reads = 0
    private(set) var applied: [Int] = []
    private var timestamp: Double = 0

    init(own: Visibility) {
        let input = HarnessInputPending(), clock = HarnessClock()
        self.input = input
        self.clock = clock
        node = VisibilityNode(root: "window", own: own)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in HarnessFrameLink() }
    }

    /// Observes `model.value`; `onApply` runs inside each apply.
    func watch(onApply: @escaping @MainActor () -> Void = {}) -> VisibleObservation<Int> {
        VisibleObservation(node, owner: "test.watch", on: work, causes: causes) { [self] in
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
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class HarnessClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
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
