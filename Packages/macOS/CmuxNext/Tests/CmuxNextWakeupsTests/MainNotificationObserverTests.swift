import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextWakeups

/// Classed main work that is not a Swift job (plans/cmux-next/chrome-parity/p04-input.md, task 080):
/// a notification, a run-loop block or a GCD-style post names its class. Input and frame work runs at
/// once; userBlocking, visible, automation and background work is held while the MainJobGate says a
/// person's input is pending or in dispatch, goes in order after the input's commit (or one refresh
/// later), and then runs as its class's budget lets it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MainNotificationObserverTests {
    static let name = Notification.Name("MainNotificationObserverTests.ping")
    static let classes: [MainWorkClass] = [.input, .frame, .visible, .automation, .background]

    /// While an input's dispatch runs, a notification's visible, automation and background handlers
    /// wait; its input and frame handlers run in the delivery. The rest go after the commit that
    /// follows the dispatch, in class order.
    @Test func visibleAutomationAndBackgroundWaitWhileAnInputDispatchRuns() {
        let rig = ClassedRig()
        var ran: [String] = []
        let observers = Self.classes.map { workClass in
            MainNotificationObserver(Self.name, center: rig.center, class: workClass, owner: "test.\(workClass)", on: rig.work) {
                ran.append(workClass.description)
            }
        }
        let outer = rig.state.beginDispatch()
        rig.center.post(name: Self.name, object: nil)
        #expect(Set(ran) == ["input", "frame"], "input and frame run in the notification's delivery")
        #expect(rig.work.heldClassedCount == 3)
        rig.turns.runAll()
        rig.work.classedHoldCommitted()
        #expect(Set(ran) == ["input", "frame"], "the dispatch still runs: nothing else goes at this commit")
        rig.state.endDispatch(restoring: outer)
        rig.work.classedHoldCommitted()
        #expect(rig.work.heldClassedCount == 0)
        #expect(rig.deadlines.pending == 0, "the commit's release cancels the deadline")
        rig.turns.runAll()
        #expect(ran.suffix(3) == ["visible", "automation", "background"])
        withExtendedLifetime(observers) {}
    }

    /// With no input, a visible handler runs in its notification's delivery (an idle scheduler).
    @Test func aQuietGateRunsAVisibleHandlerInItsDelivery() {
        let rig = ClassedRig()
        var runs = 0
        let observer = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.visible", on: rig.work) {
            runs += 1
        }
        rig.center.post(name: Self.name, object: nil)
        #expect(runs == 1)
        #expect(rig.work.heldClassedCount == 0)
        observer.cancel()
        rig.center.post(name: Self.name, object: nil)
        #expect(runs == 1, "a cancelled observer stops")
    }

    /// A delivery held behind input is dropped when its observer is cancelled or released before
    /// the hold ends: the handler never runs against a torn-down owner.
    @Test func aHeldDeliveryNeverRunsAfterItsObserverIsCancelledOrReleased() {
        let rig = ClassedRig()
        var ran: [String] = []
        let cancelled = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.cancelled",
                                                 on: rig.work) { ran.append("cancelled") }
        var released: MainNotificationObserver? = MainNotificationObserver(
            Self.name, center: rig.center, class: .automation, owner: "test.released", on: rig.work
        ) { ran.append("released") }
        let kept = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.kept", on: rig.work) {
            ran.append("kept")
        }
        rig.state.publish(.key)
        rig.center.post(name: Self.name, object: nil)
        #expect(rig.work.heldClassedCount == 3)
        cancelled.cancel()
        released = nil
        rig.state.publish([])
        rig.work.classedHoldCommitted()
        rig.turns.runAll()
        #expect(ran == ["kept"])
        withExtendedLifetime((kept, released)) {}
    }

    /// The read form reads the notification in its delivery, though the handler waits.
    @Test func theReadFormReadsInTheDeliveryAndHandsTheValueOnLater() {
        let rig = ClassedRig()
        let sender = NSObject()
        var got: [ObjectIdentifier] = []
        let observer = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.read", on: rig.work,
                                                read: { $0.object as? NSObject }) { object in
            if let object { got.append(ObjectIdentifier(object)) }
        }
        rig.state.publish(.key)
        rig.center.post(name: Self.name, object: sender)
        #expect(got.isEmpty)
        rig.state.publish([])
        rig.work.classedHoldCommitted()
        rig.turns.runAll()
        #expect(got == [ObjectIdentifier(sender)])
        withExtendedLifetime(observer) {}
    }

    /// `post(class:)`: input and frame work runs on the next turn though a key is pending, and input
    /// counts as pending input until then; a visible post waits, and one posted after the input
    /// ended still queues behind it.
    @Test func classedPostsPassOrWaitAndKeepTheirOrderAcrossTheHold() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.state.publish(.key)
        rig.work.post(class: .visible, owner: "a") { ran.append("a") }
        rig.work.post(class: .input, owner: "key") { ran.append("key") }
        rig.work.post(class: .frame, owner: "spring") { ran.append("spring") }
        #expect(ran.isEmpty, "a post never runs inline")
        #expect(rig.work.board.pendingInputCount == 1)
        rig.turns.runAll()
        #expect(ran == ["key", "spring"])
        #expect(rig.work.board.pendingInputCount == 0)
        rig.state.publish([])
        rig.work.post(class: .visible, owner: "b") { ran.append("b") }
        #expect(rig.work.heldClassedCount == 2, "b queues behind the held a")
        rig.work.classedHoldCommitted()
        rig.turns.runAll()
        #expect(ran == ["key", "spring", "a", "b"])
    }

    /// A plain budgeted post (`post(_:)`, as `apply` and `reply` use) made while classed work of its
    /// class is held queues behind that work: each class keeps one FIFO across the hold, so the
    /// newer state is written last.
    @Test func aPlainPostWaitsBehindClassedWorkHeldBeforeIt() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.state.publish(.key)
        rig.work.post(class: .visible, owner: "held") { ran.append("held") }
        rig.work.post(.visible, owner: "plain") { ran.append("plain") }
        #expect(rig.work.heldClassedCount == 2, "the plain post joins the hold")
        rig.state.publish([])
        rig.work.classedHoldCommitted()
        rig.turns.runAll()
        #expect(ran == ["held", "plain"])
    }

    /// A classed callback in a notification's callout runs only itself: posted work queued before
    /// it, in its class or another, never runs nested inside the poster's task.
    @Test func aCalloutRunsOnlyItsOwnCallback() {
        let rig = ClassedRig()
        var ran: [String] = []
        let observer = MainNotificationObserver(Self.name, center: rig.center, class: .automation, owner: "test.callout",
                                                on: rig.work) { ran.append("handler") }
        rig.work.post(.visible, owner: "outer") {
            ran.append("outer.start")
            rig.center.post(name: Self.name, object: nil)
            ran.append("outer.end")
        }
        rig.work.post(.visible, owner: "sibling") { ran.append("sibling") }
        rig.turns.runAll()
        #expect(ran.count == 4)
        let outerEnd = ran.firstIndex(of: "outer.end") ?? .max, sibling = ran.firstIndex(of: "sibling") ?? -1
        #expect(outerEnd < sibling, "the sibling queued before the notification runs after the poster's task")
        #expect(ran.filter { $0 == "handler" }.count == 1)

        ran.removeAll()
        rig.work.post(.automation, owner: "earlier") { ran.append("earlier") }
        rig.center.post(name: Self.name, object: nil)
        #expect(ran.isEmpty, "with automation work queued ahead, the callback queues behind it")
        rig.turns.runAll()
        #expect(ran == ["earlier", "handler"])
        withExtendedLifetime(observer) {}
    }

    /// One refresh after the first was held, the held work goes, though input is still pending.
    @Test func theOneRefreshDeadlineReleasesWhileInputStaysPending() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.state.publish(.key)
        rig.work.post(class: .background, owner: "late") { ran.append("late") }
        rig.work.post(class: .visible, owner: "later") { ran.append("later") }
        #expect(rig.deadlines.delays == [.nanoseconds(Int64(rig.work.frames.refreshPeriod * 1_000_000_000))],
                "the first hold arms one deadline, one refresh out")
        rig.work.classedHoldCommitted()
        #expect(rig.work.heldClassedCount == 2)
        rig.deadlines.fireAll()
        #expect(rig.work.heldClassedCount == 0)
        rig.turns.runAll()
        #expect(Set(ran) == ["late", "later"])
    }

    /// On the real main run loop with input still pending, the deadline's timer wakes the sleeping
    /// run loop and releases the held work; no commit releases it while the key stays pending.
    @Test func theDeadlineWakesASleepingRunLoop() {
        let rig = ClassedRig(realDeadline: true)
        var ran: [String] = []
        rig.state.publish(.key)
        rig.work.post(class: .visible, owner: "held") { ran.append("held") }
        #expect(rig.work.heldClassedCount == 1)
        spinMainRunLoop { rig.work.heldClassedCount == 0 }
        #expect(rig.work.heldClassedCount == 0, "the deadline released it though the key is still pending")
        rig.turns.runAll()
        #expect(ran == ["held"])
    }

    /// The gate's rule: input pending or in dispatch holds; a nested run loop or a stopped gate does
    /// not, and neither do held Swift jobs alone.
    @Test func holdingFollowsTheGateWord() {
        #expect(MainJobGateSwitch.holds([.key]))
        #expect(MainJobGateSwitch.holds([.dispatching]))
        #expect(!MainJobGateSwitch.holds([]))
        #expect(!MainJobGateSwitch.holds([.held]))
        #expect(!MainJobGateSwitch.holds([.key, .nestedLoop]))
        #expect(!MainJobGateSwitch.holds([.dispatching, .bypass]))
    }

    /// On the real main run loop: a classed run-loop block and a post from any thread wait while the
    /// dispatch runs, also across its commits, and go after the first commit that follows it; a plain
    /// post from any thread that arrives meanwhile waits behind them; an input post runs in its
    /// arrival turn.
    @Test func runLoopBlocksAndAnyThreadPostsGoAfterTheCommit() {
        let rig = ClassedRig()
        let log = ClassedLog()
        let outer = rig.state.beginDispatch()
        MainRunLoopBlock.perform(class: rig.work.callbackClass(.visible, owner: "block")) { log.entries.append("block") }
        let owner = rig.work.board.owner("any-thread")
        rig.work.postFromAnyThread(class: .automation, owner: owner) { log.entries.append("automation") }
        rig.work.postFromAnyThread(class: .input, owner: owner) { log.entries.append("input") }
        rig.work.postFromAnyThread(.automation, owner: owner) { log.entries.append("plain") }
        spinMainRunLoop { log.entries == ["input"] && rig.work.heldClassedCount == 3 }
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        #expect(log.entries == ["input"])
        #expect(rig.work.heldClassedCount == 3, "the commits while the dispatch runs release nothing")
        rig.state.endDispatch(restoring: outer)
        spinMainRunLoop { rig.work.heldClassedCount == 0 }
        rig.turns.runAll()
        #expect(log.entries == ["input", "block", "automation", "plain"])
    }

    private func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// A scheduler whose classed work follows a gate word the test sets, on a clock, turns and
/// deadlines it drives (or the real deadline timer with `realDeadline`).
@MainActor
private final class ClassedRig {
    let state: InputPendingState
    let center = NotificationCenter()
    let turns: ClassedTurns
    let clock: ClassedClock
    let deadlines = ClassedDeadlines()
    let work: MainWorkScheduler

    init(realDeadline: Bool = false) {
        let state = InputPendingState(), turns = ClassedTurns(), clock = ClassedClock()
        (self.state, self.turns, self.clock) = (state, turns, clock)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { turns.queue($0) }) { _ in
            ClassedFakeLink()
        }
        work.holdsClassedWork = { MainJobGateSwitch.holds(state.bits) }
        if !realDeadline {
            let deadlines = deadlines
            work.armClassedDeadline = { delay, fire in deadlines.arm(delay, fire) }
        }
    }
}

/// What the classed work ran, in order.
@MainActor
private final class ClassedLog {
    var entries: [String] = []
}

/// The turns the scheduler queued, run when the test says.
@MainActor
private final class ClassedTurns {
    private var pending: [@MainActor () -> Void] = []

    func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

    func runAll() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

/// The held work's deadlines, fired when the test says.
@MainActor
private final class ClassedDeadlines {
    private var armed: [Int: @MainActor () -> Void] = [:]
    private var next = 0
    private(set) var delays: [Duration] = []

    /// Deadlines armed and not fired or cancelled.
    var pending: Int { armed.count }

    func arm(_ delay: Duration, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        next += 1
        let id = next
        armed[id] = fire
        delays.append(delay)
        return { [weak self] in self?.armed[id] = nil }
    }

    func fireAll() {
        let due = armed.sorted { $0.key < $1.key }.map(\.value)
        armed.removeAll()
        for fire in due { fire() }
    }
}

/// The budget's clock (`CLOCK_UPTIME_RAW` nanoseconds), moved by hand.
@MainActor
private final class ClassedClock {
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}

@MainActor
private final class ClassedFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
