import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextWakeups

/// Classed main work that is not a Swift job (plans/cmux-next/chrome-parity/p04-input.md, task 080):
/// a notification, a run-loop block or a GCD-style post names its class. Input and frame work runs at
/// once; userBlocking, visible, automation and background work runs as its class's budget lets it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MainNotificationObserverTests {
    static let name = Notification.Name("MainNotificationObserverTests.ping")

    /// On an idle scheduler a visible handler runs in its notification's delivery.
    @Test func aVisibleHandlerRunsInItsDelivery() {
        let rig = ClassedRig()
        var runs = 0
        let observer = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.visible", on: rig.work) {
            runs += 1
        }
        rig.center.post(name: Self.name, object: nil)
        #expect(runs == 1)
        observer.cancel()
        rig.center.post(name: Self.name, object: nil)
        #expect(runs == 1, "a cancelled observer stops")
    }

    /// A delivery queued behind earlier work of its class is dropped when its observer is cancelled
    /// or released before it runs: the handler never runs against a torn-down owner.
    @Test func aQueuedDeliveryNeverRunsAfterItsObserverIsCancelledOrReleased() {
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
        rig.work.post(.visible, owner: "earlier.visible") { ran.append("earlier.visible") }
        rig.work.post(.automation, owner: "earlier.automation") { ran.append("earlier.automation") }
        rig.center.post(name: Self.name, object: nil)
        #expect(ran.isEmpty, "every delivery queued behind the earlier work of its class")
        cancelled.cancel()
        released = nil
        rig.turns.runAll()
        #expect(ran.filter { $0.hasSuffix("visible") || $0 == "kept" } == ["earlier.visible", "kept"])
        #expect(Set(ran) == ["earlier.visible", "kept", "earlier.automation"], "the cancelled and the released never ran")
        withExtendedLifetime((kept, released)) {}
    }

    /// The read form reads the notification in its delivery, though the handler waits in its class.
    @Test func theReadFormReadsInTheDeliveryAndHandsTheValueOnLater() {
        let rig = ClassedRig()
        let sender = NSObject()
        var got: [ObjectIdentifier] = []
        let observer = MainNotificationObserver(Self.name, center: rig.center, class: .visible, owner: "test.read", on: rig.work,
                                                read: { $0.object as? NSObject }) { object in
            if let object { got.append(ObjectIdentifier(object)) }
        }
        rig.work.post(.visible, owner: "earlier") {}
        rig.center.post(name: Self.name, object: sender)
        #expect(got.isEmpty, "the handler queued behind the earlier visible work")
        rig.turns.runAll()
        #expect(got == [ObjectIdentifier(sender)])
        withExtendedLifetime(observer) {}
    }

    /// `post(class:)` of visible work goes to its class queue, never inline, and keeps one FIFO with plain posts.
    @Test func classedVisiblePostsKeepTheirOrderWithPlainPosts() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.work.post(class: .visible, owner: "a") { ran.append("a") }
        rig.work.post(.visible, owner: "b") { ran.append("b") }
        rig.work.post(class: .visible, owner: "c") { ran.append("c") }
        #expect(ran.isEmpty, "a post never runs inline")
        rig.turns.runAll()
        #expect(ran == ["a", "b", "c"])
    }

    /// `post(class:)` of input and frame work runs on the next turn, and input counts as pending input until then.
    @Test func inputAndFramePostsRunOnTheNextTurn() {
        let rig = ClassedRig()
        var ran: [String] = []
        rig.work.post(class: .input, owner: "key") { ran.append("key") }
        rig.work.post(class: .frame, owner: "spring") { ran.append("spring") }
        #expect(ran.isEmpty, "a post never runs inline")
        #expect(rig.work.board.pendingInputCount == 1)
        rig.turns.runAll()
        #expect(ran == ["key", "spring"])
        #expect(rig.work.board.pendingInputCount == 0)
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

    /// An off-main input post counts as pending input from its post until it runs on the main run loop; visible work
    /// posted meanwhile yields to it and runs after.
    @Test func anOffMainInputPostIsPendingInputUntilItRuns() {
        let rig = ClassedRig()
        let log = ClassedLog()
        rig.work.postFromAnyThread(class: .input, owner: rig.work.board.owner("any-thread")) { log.entries.append("input") }
        #expect(rig.work.board.pendingInputCount == 1)
        rig.work.post(.visible, owner: "visible") { log.entries.append("visible") }
        spinMainRunLoop { log.entries == ["input"] }
        #expect(log.entries == ["input"])
        #expect(rig.work.board.pendingInputCount == 0)
        rig.turns.runAll()
        #expect(log.entries == ["input", "visible"])
    }

    /// On the real main run loop with no input pending: a classed run-loop block runs in its callout and off-main posts
    /// (`postFromAnyThread`, made here on main) run in their arrival turns, each class in its FIFO order.
    @Test func runLoopBlocksAndAnyThreadPostsRunOnTheMainRunLoop() {
        let rig = ClassedRig()
        let log = ClassedLog()
        MainRunLoopBlock.perform(class: rig.work.callbackClass(.visible, owner: "block")) { log.entries.append("block") }
        let owner = rig.work.board.owner("any-thread")
        rig.work.postFromAnyThread(class: .automation, owner: owner) { log.entries.append("automation") }
        rig.work.postFromAnyThread(.automation, owner: owner) { log.entries.append("plain") }
        spinMainRunLoop { log.entries.count == 3 }
        rig.turns.runAll()
        #expect(log.entries == ["block", "automation", "plain"])
    }

    private func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// A scheduler on a clock and turns the test drives.
@MainActor
private final class ClassedRig {
    let center = NotificationCenter()
    let turns: ClassedTurns
    let clock: ClassedClock
    let work: MainWorkScheduler

    init() {
        let turns = ClassedTurns(), clock = ClassedClock()
        (self.turns, self.clock) = (turns, clock)
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: { turns.queue($0) }) { _ in
            ClassedFakeLink()
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
