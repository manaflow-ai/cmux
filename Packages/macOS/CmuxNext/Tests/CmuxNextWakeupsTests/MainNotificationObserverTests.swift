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
        rig.work.classedHoldStage(.beforeWaiting)
        #expect(Set(ran) == ["input", "frame"], "the dispatch still runs: nothing else goes at this commit")
        rig.state.endDispatch(restoring: outer)
        rig.work.classedHoldStage(.beforeWaiting)
        #expect(rig.work.heldClassedCount == 0)
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
        rig.work.classedHoldStage(.beforeWaiting)
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
        rig.work.classedHoldStage(.beforeWaiting)
        rig.turns.runAll()
        #expect(ran == ["key", "spring", "a", "b"])
    }

    /// One refresh after the first was held, the held work goes, though input is still pending.
    @Test func theOneRefreshDeadlineReleasesWhileInputStaysPending() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.state.publish(.key)
        rig.work.post(class: .background, owner: "late") { ran.append("late") }
        rig.clock.now += 10_000_000
        rig.work.classedHoldStage(.beforeTimers)
        rig.work.classedHoldStage(.beforeWaiting)
        #expect(rig.work.heldClassedCount == 1)
        rig.clock.now += 7_000_000
        rig.work.classedHoldStage(.beforeTimers)
        #expect(rig.work.heldClassedCount == 0)
        rig.turns.runAll()
        #expect(ran == ["late"])
    }

    /// The gate's rule: input pending or in dispatch holds; a nested run loop or a stopped gate does
    /// not, and neither do held Swift jobs alone.
    @Test func holdingFollowsTheGateWord() {
        #expect(MainJobGateSwitch.holdsMainWork([.key]))
        #expect(MainJobGateSwitch.holdsMainWork([.dispatching]))
        #expect(!MainJobGateSwitch.holdsMainWork([]))
        #expect(!MainJobGateSwitch.holdsMainWork([.held]))
        #expect(!MainJobGateSwitch.holdsMainWork([.key, .nestedLoop]))
        #expect(!MainJobGateSwitch.holdsMainWork([.dispatching, .bypass]))
    }

    /// On the real main run loop: a classed run-loop block and a post from any thread wait while the
    /// dispatch runs, also across its commits, and go after the first commit that follows it; an
    /// input post runs in its arrival turn.
    @Test func runLoopBlocksAndAnyThreadPostsGoAfterTheCommit() {
        let rig = ClassedRig()
        let log = ClassedLog()
        let outer = rig.state.beginDispatch()
        MainRunLoopBlock.perform(class: rig.work.callbackClass(.visible, owner: "block")) { log.entries.append("block") }
        let owner = rig.work.board.owner("any-thread")
        rig.work.postFromAnyThread(class: .automation, owner: owner) { log.entries.append("automation") }
        rig.work.postFromAnyThread(class: .input, owner: owner) { log.entries.append("input") }
        spinMainRunLoop { log.entries == ["input"] && rig.work.heldClassedCount == 2 }
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        #expect(log.entries == ["input"])
        #expect(rig.work.heldClassedCount == 2, "the commits while the dispatch runs release nothing")
        rig.state.endDispatch(restoring: outer)
        spinMainRunLoop { rig.work.heldClassedCount == 0 }
        rig.turns.runAll()
        #expect(log.entries == ["input", "block", "automation"])
    }

    private func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// A scheduler whose classed work follows a gate word the test sets, on a clock and turns it drives.
@MainActor
private final class ClassedRig {
    let state: InputPendingState
    let center = NotificationCenter()
    let turns: ClassedTurns
    let clock: ClassedClock
    let work: MainWorkScheduler

    init() {
        let state = InputPendingState(), turns = ClassedTurns(), clock = ClassedClock()
        (self.state, self.turns, self.clock) = (state, turns, clock)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { turns.queue($0) }) { _ in
            ClassedFakeLink()
        }
        work.holdsClassedWork = { MainJobGateSwitch.holdsMainWork(state.bits) }
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
