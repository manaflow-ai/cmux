import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// ServiceObservation (plans/cmux-next/chrome-parity/p06-scheduler.md, task 026): a non-view
/// owner's observer. The first value applies at once; a burst of changes gives one apply in the
/// observer's class on the next frame; Equatable values dedupe; releasing the token stops it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ServiceObservationTests {
    @MainActor @Observable final class Model {
        var count = 0
        var name = "a"
    }

    @Test func theFirstValueAppliesBeforeInitReturns() {
        let fixture = Fixture()
        let model = Model()
        model.count = 7
        var applied: [Int] = []
        let token = ServiceObservation(.background, owner: "test.first", on: fixture.work) { model.count } apply: { applied.append($0) }
        #expect(applied == [7])
        withExtendedLifetime(token) {}
    }

    @Test func aBurstOfChangesGivesOneReadAndOneApplyOnTheNextFrame() {
        let fixture = Fixture()
        let model = Model()
        var reads = 0
        var applied: [Int] = []
        let token = ServiceObservation(.visible, owner: "test.burst", on: fixture.work) {
            reads += 1
            return model.count
        } apply: { applied.append($0) }
        for value in 1...5 { model.count = value }
        #expect(applied == [0], "nothing applies in the turn of the changes")
        #expect(reads == 1)
        fixture.frame()
        #expect(reads == 2, "five changes, one evaluation")
        #expect(applied == [0, 5], "five changes, one apply of the latest value")
        fixture.frame()
        #expect(reads == 2, "no change, no work on the next frame")
        model.count = 6
        fixture.frame()
        #expect(applied == [0, 5, 6], "the tracking re-arms after each flush")
        withExtendedLifetime(token) {}
    }

    @Test func anEqualValueDoesNotApplyAgain() {
        let fixture = Fixture()
        let model = Model()
        var reads = 0
        var applied: [String] = []
        let token = ServiceObservation(.automation, owner: "test.dedupe", on: fixture.work) {
            reads += 1
            return model.name
        } apply: { applied.append($0) }
        model.name = "b"
        model.name = "a"
        fixture.frame()
        #expect(reads == 2)
        #expect(applied == ["a"], "a change and its undo in one burst apply nothing")
        model.name = "c"
        fixture.frame()
        #expect(applied == ["a", "c"])
        withExtendedLifetime(token) {}
    }

    @Test func aNonEquatableValueAppliesEveryEvaluation() {
        let fixture = Fixture()
        let model = Model()
        var applies = 0
        let token = ServiceObservation(.background, owner: "test.trigger", on: fixture.work) { _ = model.count } apply: { _ in applies += 1 }
        model.count = 1
        fixture.frame()
        #expect(applies == 2, "Void cannot be compared: the initial apply and one per flush")
        withExtendedLifetime(token) {}
    }

    @Test func releasingTheTokenStopsEveryCallback() {
        let fixture = Fixture()
        let model = Model()
        var reads = 0
        var applies = 0
        var token: ServiceObservation<Int>? = ServiceObservation(.visible, owner: "test.release", on: fixture.work) {
            reads += 1
            return model.count
        } apply: { _ in applies += 1 }
        weak var released = token
        model.count = 1
        token = nil
        #expect(released == nil, "the frame client must not keep the observation alive")
        fixture.frame()
        model.count = 2
        fixture.frame()
        #expect(reads == 1)
        #expect(applies == 1, "only the initial apply ran")
    }

    @Test func cancelStopsEveryCallback() {
        let fixture = Fixture()
        let model = Model()
        var applies = 0
        let token = ServiceObservation(.visible, owner: "test.cancel", on: fixture.work) { model.count } apply: { _ in applies += 1 }
        model.count = 1
        token.cancel()
        fixture.frame()
        model.count = 2
        fixture.frame()
        #expect(token.isCancelled)
        #expect(applies == 1)
    }

    @Test func eachFlushRunsAsATaskOfItsClassAndOwner() {
        let fixture = Fixture()
        let model = Model()
        var ran: [String] = []
        var tasks: [MainTaskBoard.Task?] = []
        let board = fixture.work.budget.board
        // Made lowest class first: the frame still runs them in class order.
        let background = ServiceObservation(.background, owner: "test.background", on: fixture.work) { model.count } apply: { _ in
            ran.append("background")
            tasks.append(board.running)
        }
        let automation = ServiceObservation(.automation, owner: "test.automation", on: fixture.work) { model.count } apply: { _ in
            ran.append("automation")
            tasks.append(board.running)
        }
        let visible = ServiceObservation(.visible, owner: "test.visible", on: fixture.work) { model.count } apply: { _ in
            ran.append("visible")
            tasks.append(board.running)
        }
        ran.removeAll()
        tasks.removeAll()
        model.count = 1
        fixture.frame()
        #expect(ran == ["visible", "automation", "background"])
        #expect(tasks.map { $0?.workClass } == [.visible, .automation, .background])
        #expect(tasks.map { $0?.owner } == ["test.visible", "test.automation", "test.background"])
        withExtendedLifetime((background, automation, visible)) {}
    }

    @Test func pendingInputHoldsTheFlushForOneFrame() {
        let fixture = Fixture()
        let model = Model()
        var applied: [Int] = []
        let token = ServiceObservation(.automation, owner: "test.input", on: fixture.work) { model.count } apply: { applied.append($0) }
        model.count = 1
        fixture.input.pending = true
        fixture.frame()
        #expect(applied == [0], "a pending key goes first: the automation flush waits")
        fixture.frame()
        #expect(applied == [0, 1], "held one frame, never two")
        withExtendedLifetime(token) {}
    }

    @Test func aChangeMadeByApplyFlushesOnTheNextFrame() {
        let fixture = Fixture()
        let model = Model()
        var applied: [Int] = []
        let token = ServiceObservation(.background, owner: "test.reentrant", on: fixture.work) { model.count } apply: { value in
            applied.append(value)
            if value == 1 { model.count = 2 }
        }
        model.count = 1
        fixture.frame()
        #expect(applied == [0, 1])
        fixture.frame()
        #expect(applied == [0, 1, 2], "the change apply made is not lost")
        withExtendedLifetime(token) {}
    }
}

/// The app's scheduler on a fake link, a clock the test moves and an input source it sets.
@MainActor
private struct Fixture {
    let clock = ServiceClock()
    let input = ServiceInputPending()
    let work: MainWorkScheduler
    private let frames = FrameCounter()

    init() {
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        work = MainWorkScheduler.testing(budget: budget, clock: ManualClock()) { _ in ServiceFakeLink() }
    }

    /// One display frame, a frame period after the last.
    func frame() {
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: frames.next(), refreshInterval: 1.0 / 60)
    }
}

@MainActor
private final class FrameCounter {
    private var timestamp: Double = 0
    func next() -> Double {
        timestamp += 1
        return timestamp
    }
}

/// `CLOCK_UPTIME_RAW` nanoseconds the test moves.
@MainActor
private final class ServiceClock {
    private var now: UInt64 = 1_000_000_000
    // Strong: the scheduler's stall timer may read it after the test returned.
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class ServiceInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class ServiceFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
