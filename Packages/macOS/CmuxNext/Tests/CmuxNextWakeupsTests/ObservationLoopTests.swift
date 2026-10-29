import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// ObservationLoop: a render loop on FrameObservation. One scheduled render per
/// dirty period and one per frame, never a task per change; a person-caused change renders in the
/// input-response pass before any frame; a hidden node renders nothing until it shows; an
/// automation loop renders with no display link; a cancelled loop renders nothing.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ObservationLoopTests {
    @Test func aHundredChangesRenderOnceInTheNextFrame() {
        let rig = LoopRig()
        let loop = rig.loop(.visible(rig.node))
        #expect(rig.rendered == [0], "init renders once, in the caller's turn")
        for value in 1...100 { rig.model.value = value }
        #expect(loop.deliveriesScheduled == 1, "one render scheduled for 100 changes, not one task per change")
        #expect(rig.rendered == [0], "a change rendered in its own turn")
        rig.frame()
        #expect(rig.rendered == [0, 100])
        rig.frame()
        #expect(rig.rendered == [0, 100], "a frame with no change rendered")
        rig.model.value = 101
        rig.frame()
        #expect(rig.rendered == [0, 100, 101], "the render did not track again")
        rig.stop(loop)
    }

    /// The input-response pass (InputResponsePass, before the commit) applies the person's
    /// observations through `causes.flushPersonCaused()`: the chrome shows the person's change
    /// in the frame that input commits, with no frame tick.
    @Test func aPersonCausedChangeRendersInTheInputResponsePass() {
        let rig = LoopRig()
        let loop = rig.loop(.visible(rig.node))
        rig.input.pending = true
        rig.work.causes.withCause(.person) { rig.model.value = 1 }
        #expect(rig.rendered == [0])
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(rig.rendered == [0, 1], "the person's change waited for a frame")
        rig.input.pending = false
        rig.frame()
        #expect(rig.rendered == [0, 1], "the scheduled render ran again after the pass")
        rig.stop(loop)
    }

    @Test func aHiddenNodeRendersNothingUntilItShows() {
        let rig = LoopRig()
        let loop = rig.loop(.visible(rig.node))
        rig.node.set(.hidden)
        rig.model.value = 1
        rig.model.value = 2
        rig.frame()
        #expect(rig.rendered == [0], "a hidden tab's chrome rendered")
        rig.node.set(.visible)
        #expect(rig.rendered == [0, 2], "showing did not render the change once")
        rig.frame()
        #expect(rig.rendered == [0, 2])
        rig.stop(loop)
    }

    /// No display link at all (an occluded window, a headless run): an automation loop renders on
    /// the next main run loop turn.
    @Test func anAutomationLoopRendersWithNoDisplayLink() {
        let rig = LoopRig(makeLink: false)
        let loop = rig.loop(.automation)
        rig.model.value = 5
        #expect(rig.rendered == [0])
        rig.spinMainRunLoop { rig.rendered.count > 1 }
        #expect(rig.rendered == [0, 5])
        rig.stop(loop)
    }

    /// The read/apply form: only `read` is tracked, and it runs once per render, never in a will-set.
    @Test func aReadAndApplyLoopReadsOncePerRenderAndFollowsOnlyItsRead() {
        let rig = LoopRig()
        var reads = 0, applied: [Int] = []
        let loop = ObservationLoop(owner: "test.observationLoop.split", delivery: .visible(rig.node), on: rig.work) {
            reads += 1
            return rig.model.value
        } apply: { value in
            _ = rig.model.other
            applied.append(value)
        }
        #expect(reads == 1 && applied == [0], "init reads and applies once, in the caller's turn")
        for value in 1...10 { rig.model.value = value }
        #expect(reads == 1, "a will-set ran the read")
        rig.frame()
        #expect(reads == 2 && applied == [0, 10])
        rig.model.other = 1
        rig.frame()
        #expect(reads == 2 && applied == [0, 10], "a change of what only the apply read rendered")
        rig.work.causes.withCause(.person) { rig.model.value = 11 }
        #expect(reads == 2, "the person's will-set ran the read")
        #expect(rig.work.causes.flushPersonCaused() == 1)
        #expect(reads == 3 && applied == [0, 10, 11], "the person's change waited for a frame")
        rig.stop(loop)
    }

    @Test func aCancelledLoopRendersNothing() {
        let rig = LoopRig()
        let loop = rig.loop(.visible(rig.node))
        loop.cancel()
        rig.model.value = 1
        rig.frame()
        rig.work.causes.withCause(.person) { rig.model.value = 2 }
        #expect(rig.work.causes.flushPersonCaused() == 0)
        #expect(rig.rendered == [0], "a cancelled loop rendered")
        #expect(loop.isCancelled)
        rig.stop(loop)
    }
}

@MainActor @Observable
private final class LoopModel {
    var value = 0
    var other = 0
}

/// A scheduler on a fake link (or none), a hand-moved budget clock, and a loop that records what it rendered.
@MainActor
private final class LoopRig {
    let model = LoopModel()
    let input: LoopInputPending
    let node = VisibilityNode(root: "window", own: .visible)
    let work: MainWorkScheduler
    private let clock: LoopClock
    private var timestamp: Double = 0
    private var keeper: FrameClient?
    private(set) var rendered: [Int] = []

    /// - Parameter makeLink: false: the link factory returns nil.
    init(makeLink: Bool = true) {
        let input = LoopInputPending(), clock = LoopClock()
        self.input = input
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                         clock: ManualClock()) { _ -> (any FrameLink)? in
            guard makeLink else { return nil }
            return LoopFrameLink()
        }
        guard makeLink else { return }
        // Frames run (as while anything animates), so a visible render waits for a hand-fired frame.
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        self.keeper = keeper
    }

    func loop(_ delivery: FrameObservationDelivery) -> ObservationLoop {
        ObservationLoop(owner: "test.observationLoop", delivery: delivery, on: work) { [unowned self] in
            rendered.append(model.value)
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

    func stop(_ loop: ObservationLoop) {
        loop.cancel()
        keeper?.deactivate()
    }
}

@MainActor
private final class LoopClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: UInt64) { now += ms * 1_000_000 }
}

@MainActor
private final class LoopInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class LoopFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
