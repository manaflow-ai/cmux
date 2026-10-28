@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The sequence manager's core (plans/cmux-next/sequence-manager-DESIGN.md section 2.1, step S2a):
/// general task queues with a priority, enable voters, a fence and continuations, and the selector
/// that picks the next task across them (Chrome `TaskQueueSelector`). Nothing in the app uses them
/// yet; time comes from a ``ManualClock``.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainTaskSelectorTests {
    private let board = MainTaskBoard()

    private func rig() -> (MainTaskSelector, ManualClock) {
        let clock = ManualClock()
        return (MainTaskSelector(clock: clock), clock)
    }

    /// Runs every task the selector gives, in its order.
    private func drain(_ selector: MainTaskSelector, admitting admits: (MainQueueType) -> Bool = { _ in true }) {
        while selector.runNext(admitting: admits) {}
    }

    @Test("Strictly the highest priority with a runnable task first, whatever the post order")
    func strictPriority() {
        let (selector, _) = rig()
        var ran: [String] = []
        let order: [MainQueueType] = [.idle, .background, .automation, .visible, .userBlocking, .input, .control]
        let queues = order.map { selector.queue($0, owner: board.owner("\($0)")) }
        for queue in queues { queue.post { ran.append("\(queue.type)") } }
        #expect(selector.runNext())
        #expect(ran == ["control"])
        // A higher task posted now goes before every lower one already waiting.
        queues[5].post { ran.append("input again") }
        drain(selector)
        #expect(ran == ["control", "input", "input again", "userBlocking", "visible", "automation", "background", "idle"])
        #expect(!selector.runNext(), "nothing left")
    }

    @Test("Startup has visible's priority, and types of one priority share one selection rule")
    func startupSharesVisiblePriority() {
        #expect(MainQueueType.startup.priority == MainQueueType.visible.priority)
        for one in MainQueueType.allCases {
            for other in MainQueueType.allCases where one.priority == other.priority {
                #expect(one.selection == other.selection, "\(one) and \(other) share a priority, so they share a rule")
            }
        }
    }

    @Test("Oldest enqueue order first across two queues of an oldest-first type", arguments: [MainQueueType.control, .input, .idle])
    func oldestFirstAcrossQueues(type: MainQueueType) {
        let (selector, _) = rig()
        var ran: [String] = []
        let first = selector.queue(type, owner: board.owner("first"))
        let second = selector.queue(type, owner: board.owner("second"))
        for index in 0..<3 { first.post { ran.append("a\(index)") } }
        second.post { ran.append("b0") }
        first.post { ran.append("a3") }
        drain(selector)
        // Round robin would give a0 b0 a1 a2 a3.
        #expect(ran == ["a0", "a1", "a2", "b0", "a3"])
    }

    @Test("Round robin by queue: a queue with 256 queued holds a later one-task queue for one task only",
          arguments: [MainQueueType.userBlocking, .startup, .visible, .automation, .background])
    func roundRobinAcrossQueues(type: MainQueueType) {
        let (selector, _) = rig()
        var ran: [String] = []
        let flood = selector.queue(type, owner: board.owner("flood"))
        let single = selector.queue(type, owner: board.owner("single"))
        for index in 0..<256 { flood.post { ran.append("a\(index)") } }
        single.post { ran.append("b0") }
        drain(selector)
        #expect(ran.count == 257)
        #expect(Array(ran.prefix(3)) == ["a0", "b0", "a1"], "the flood ran once, then the queue that ran least recently")
        #expect(Array(ran.dropFirst(2)) == (1..<256).map { "a\($0)" }, "FIFO inside the flood")
    }

    @Test("Round robin takes turns, least recently run first, across startup and visible queues")
    func roundRobinTakesTurns() {
        let (selector, _) = rig()
        var ran: [String] = []
        let names = ["x", "y", "z"]
        let queues = [MainQueueType.visible, .startup, .visible].enumerated().map { index, type in
            selector.queue(type, owner: board.owner(names[index]))
        }
        for round in 0..<2 {
            for (index, queue) in queues.enumerated() { queue.post { ran.append("\(names[index])\(round)") } }
        }
        drain(selector)
        #expect(ran == ["x0", "y0", "z0", "x1", "y1", "z1"])
    }

    @Test("A fence at now holds later posts and keeps earlier ones; lower work runs while it holds")
    func fenceAtNow() {
        let (selector, _) = rig()
        var ran: [String] = []
        let fenced = selector.queue(.visible, owner: board.owner("fenced"))
        let lower = selector.queue(.background, owner: board.owner("lower"))
        fenced.post { ran.append("before0") }
        fenced.post { ran.append("before1") }
        fenced.insertFence(.now)
        fenced.post { ran.append("after") }
        lower.post { ran.append("lower") }
        drain(selector)
        #expect(ran == ["before0", "before1", "lower"])
        #expect(fenced.isBlockedByFence && fenced.pendingCount == 1)
        fenced.removeFence()
        #expect(!fenced.isBlockedByFence)
        drain(selector)
        #expect(ran == ["before0", "before1", "lower", "after"])
    }

    @Test("A fence at the beginning of time holds every task, the ones queued before it too")
    func fenceAtBeginningOfTime() {
        let (selector, _) = rig()
        var ran: [String] = []
        let startup = selector.queue(.startup, owner: board.owner("startup"))
        startup.post { ran.append("queued") }
        startup.insertFence(.beginningOfTime)
        startup.post { ran.append("later") }
        #expect(!selector.runNext())
        // A new fence replaces the old one: both tasks were posted before it.
        startup.insertFence(.now)
        startup.post { ran.append("after") }
        drain(selector)
        #expect(ran == ["queued", "later"])
        startup.removeFence()
        drain(selector)
        #expect(ran == ["queued", "later", "after"])
    }

    @Test("A disabled voter holds a node queue; every voter must enable it; a removed voter counts as enabled")
    func voters() {
        let (selector, _) = rig()
        var ran: [String] = []
        let node = selector.queue(.visible, owner: board.owner("pane.title"))
        let other = selector.queue(.automation, owner: board.owner("other"))
        let visibility = node.makeVoter()
        let freeze = node.makeVoter()
        node.post { ran.append("node") }
        other.post { ran.append("other") }
        node.setEnabled(false, by: visibility)
        node.setEnabled(false, by: freeze)
        #expect(!node.isEnabled)
        drain(selector)
        #expect(ran == ["other"], "the held node queue let lower work run")
        node.setEnabled(true, by: visibility)
        #expect(!selector.runNext(), "one voter still disables it")
        node.removeVoter(freeze)
        node.setEnabled(false, by: freeze)
        #expect(node.isEnabled, "a removed voter's later votes are ignored")
        drain(selector)
        #expect(ran == ["other", "node"])
    }

    @Test("A continuation goes to the front of its own queue with a new enqueue order")
    func continuationOrder() {
        let (selector, _) = rig()
        var ran: [String] = []
        let first = selector.queue(.input, owner: board.owner("first"))
        let second = selector.queue(.input, owner: board.owner("second"))
        first.post {
            ran.append("a1")
            first.postContinuation { ran.append("a1 continued") }
        }
        second.post { ran.append("b1") }
        first.post { ran.append("a2") }
        drain(selector)
        // The continuation is ahead of a2 in its queue, but behind b1: it does not keep a1's old place.
        #expect(ran == ["a1", "b1", "a1 continued", "a2"])
    }

    @Test("The selector skips a type the manager does not admit and takes the next priority")
    func admitsPredicate() {
        let (selector, _) = rig()
        var ran: [String] = []
        let visible = selector.queue(.visible, owner: board.owner("visible"))
        visible.post { ran.append("visible") }
        let automation = selector.queue(.automation, owner: board.owner("automation"))
        automation.post { ran.append("automation") }
        drain(selector, admitting: { $0 != .visible })
        #expect(ran == ["automation"])
        #expect(selector.hasRunnableWork && visible.pendingCount == 1)
    }

    @Test("A taken task carries its owner, site and wait on the injected clock")
    func waitOnInjectedClock() throws {
        let (selector, clock) = rig()
        let queue = selector.queue(.automation, owner: board.owner("socket"))
        queue.post {}
        clock.advance(by: .milliseconds(5))
        queue.post {}
        clock.advance(by: .milliseconds(2))
        let first = try #require(selector.takeNext())
        #expect(first.waited == .milliseconds(7))
        #expect(first.owner.name == "socket" && first.type == .automation)
        #expect("\(first.site.file)".hasSuffix("MainTaskSelectorTests.swift"))
        let second = try #require(selector.takeNext())
        #expect(second.waited == .milliseconds(2))
        #expect(second.order > first.order)
    }

    @Test("A released queue drops its tasks and their closures at once")
    func releasedQueueDropsTasks() {
        let (selector, _) = rig()
        final class Capture {}
        weak var captured: Capture?
        var queue: MainSequenceQueue? = selector.queue(.visible, owner: board.owner("gone"))
        do {
            let capture = Capture()
            captured = capture
            queue?.post { _ = capture }
        }
        #expect(captured != nil)
        queue = nil
        #expect(captured == nil, "the closure went with its queue")
        #expect(!selector.runNext())
    }
}
