import CmuxNextWakeups
import Testing

/// Per-node task queues (MainTaskQueue.swift): a hidden node holds visible and
/// automation work and coalesces it by key, background work runs at hidden wakes, a frozen node or
/// a disabled voter runs nothing, and a released queue drops its closures.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainTaskQueueTests {
    @Test func keyedPostsWhileHiddenRunOnceOnShow() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let queue = tab.queue(.visible, owner: "Tab.title", on: rig.work)
        var ran: [Int] = []
        for index in 0..<100 {
            queue.post(key: "title") { ran.append(index) }
        }
        rig.frames(3)
        #expect(ran.isEmpty, "a hidden node ran visible work")
        #expect(queue.pendingCount == 1 && queue.isHolding)
        tab.set(.visible)
        #expect(ran.isEmpty, "a show never runs held work inline")
        rig.frames(1)
        #expect(ran == [99], "the latest body for the key runs once")
        #expect(queue.runCount(whileNode: .hidden) == 0 && queue.runCount(whileNode: .occluded) == 0)
        #expect(queue.runCount(whileNode: .visible) == 1)
        rig.stop()
    }

    @Test func heldTasksRunInPostOrderBeforeLaterPosts() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .occluded)
        let queue = window.queue(.automation, owner: "Agent.cursor", on: rig.work)
        var ran: [String] = []
        queue.post { ran.append("a") }
        queue.post(key: "k") { ran.append("old") }
        queue.post { ran.append("b") }
        queue.post(key: "k") { ran.append("k") }
        rig.frames(2)
        #expect(ran.isEmpty, "an occluded node ran automation work")
        window.set(.visible)
        queue.post { ran.append("c") }
        rig.frames(1)
        #expect(ran == ["a", "k", "b", "c"])
        rig.stop()
    }

    /// A node that hides again before its pumps run leaves the work held: nothing runs hidden.
    @Test func aHideBeforeTheFrameKeepsTheWorkHeld() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .visible)
        let queue = window.queue(.visible, owner: "Rows", on: rig.work)
        var ran = 0
        queue.post { ran += 1 }
        queue.post { ran += 1 }
        window.set(.hidden)
        rig.frames(2)
        #expect(ran == 0)
        #expect(queue.pendingCount == 2)
        window.set(.visible)
        rig.frames(1)
        #expect(ran == 2)
        #expect(queue.runCount(whileNode: .hidden) == 0)
        rig.stop()
    }

    @Test func aFrozenNodeRunsNothing() {
        let rig = QueueRig()
        var wakes: [@MainActor () -> Void] = []
        rig.work.hiddenWake = { _, wake in wakes.append(wake) }
        let window = VisibilityNode(root: "window", own: .visible)
        let visible = window.queue(.visible, owner: "Page.title", on: rig.work)
        let background = window.queue(.background, owner: "Page.persist", on: rig.work)
        var ran: [String] = []
        window.freeze()
        visible.post { ran.append("visible") }
        background.post { ran.append("background") }
        rig.frames(2)
        window.set(.hidden)
        for wake in wakes { wake() }
        rig.frames(2)
        #expect(ran.isEmpty, "a frozen node ran work")
        #expect(wakes.isEmpty, "a frozen node asked for a wake")
        window.set(.visible)
        rig.frames(1)
        #expect(ran.isEmpty, "showing does not unfreeze")
        window.unfreeze()
        rig.frames(1)
        #expect(ran == ["visible", "background"])
        rig.stop()
    }

    @Test func backgroundWorkOfAHiddenNodeRunsAtHiddenWakes() {
        let rig = QueueRig()
        var wakes: [@MainActor () -> Void] = []
        rig.work.hiddenWake = { _, wake in wakes.append(wake) }
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let background = tab.queue(.background, owner: "Tab.snapshot", on: rig.work)
        let visible = tab.queue(.visible, owner: "Tab.title", on: rig.work)
        var ran: [String] = []
        background.post { ran.append("b1") }
        background.post { ran.append("b2") }
        visible.post { ran.append("v") }
        rig.frames(2)
        #expect(ran.isEmpty)
        #expect(wakes.count == 1, "one wake for the background queue, none for the visible one")
        wakes.removeFirst()()
        background.post { ran.append("b3") }
        rig.frames(1)
        #expect(ran == ["b1", "b2"], "the wake runs what was pending at the wake")
        #expect(wakes.count == 1, "the task posted after the wake waits for the next one")
        wakes.removeFirst()()
        rig.frames(1)
        #expect(ran == ["b1", "b2", "b3"])
        #expect(background.runCount(whileNode: .hidden) == 3)
        #expect(visible.runCount(whileNode: .hidden) == 0)
        tab.set(.visible)
        rig.frames(1)
        #expect(ran.last == "v")
        rig.stop()
    }

    /// With no hidden wake installed, background work of a hidden node waits for the show.
    @Test func backgroundWorkWithoutHiddenWakesWaitsForTheShow() {
        let rig = QueueRig()
        let tab = VisibilityNode(root: "tab", own: .hidden)
        let background = tab.queue(.background, owner: "Tab.snapshot", on: rig.work)
        var ran = 0
        background.post { ran += 1 }
        rig.frames(2)
        #expect(ran == 0)
        tab.set(.visible)
        rig.frames(1)
        #expect(ran == 1)
        rig.stop()
    }

    @Test func everyVoterMustEnableTheQueue() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .visible)
        let queue = window.queue(.visible, owner: "Pane.layout", on: rig.work)
        let drag = queue.makeVoter()
        let modal = queue.makeVoter()
        queue.setEnabled(false, by: drag)
        queue.setEnabled(false, by: modal)
        var ran = 0
        queue.post { ran += 1 }
        rig.frames(1)
        #expect(ran == 0 && !queue.isEnabled)
        queue.setEnabled(true, by: drag)
        rig.frames(1)
        #expect(ran == 0, "one voter still votes disabled")
        queue.removeVoter(modal)
        queue.setEnabled(false, by: modal)
        rig.frames(1)
        #expect(ran == 1, "a removed voter's vote is gone and its later votes are ignored")
        rig.stop()
    }

    /// A released queue drops its tasks at once: the closures and what they capture are freed
    /// before any frame, and the scheduler runs nothing for them.
    @Test func aReleasedQueueReleasesItsClosures() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        weak var heldProbe: QueueProbe?
        weak var queuedProbe: QueueProbe?
        var ran = 0
        do {
            let held = tab.queue(.visible, owner: "Tab.title", on: rig.work)
            let queued = window.queue(.automation, owner: "Window.cursor", on: rig.work)
            let first = QueueProbe(), second = QueueProbe()
            heldProbe = first
            queuedProbe = second
            held.post { first.touch(); ran += 1 }
            queued.post { second.touch(); ran += 1 }
            #expect(held.pendingCount == 1 && queued.pendingCount == 1)
        }
        #expect(heldProbe == nil, "the held closure outlived its queue")
        #expect(queuedProbe == nil, "the scheduled closure outlived its queue")
        rig.frames(1)
        tab.set(.visible)
        rig.frames(1)
        #expect(ran == 0)
        rig.stop()
    }

    /// The board names the queue's owner, the class and the task's own posting site while it runs.
    @Test func theBoardNamesTheQueueOwnerAndThePostingSite() {
        let rig = QueueRig()
        let window = VisibilityNode(root: "window", own: .hidden)
        let queue = window.queue(.automation, owner: "Agent.activity", on: rig.work)
        var seen: MainTaskBoard.Task?
        let line: UInt = #line + 1
        queue.post(key: 1) { seen = rig.work.board.running }
        window.set(.visible)
        rig.frames(1)
        #expect(seen?.owner == "Agent.activity")
        #expect(seen?.workClass == .automation)
        #expect(seen?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainTaskQueueTests.swift", line: line))
        rig.stop()
    }
}

/// A scheduler on a fake link kept up by a frame client, so posts wait for hand-fired frames.
@MainActor
private final class QueueRig {
    let work: MainWorkScheduler
    private let clock: QueueClock
    private var timestamp: Double = 1
    private let keeper: FrameClient

    init() {
        let clock = QueueClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { clock.now })) { _ in QueueFakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Fires `count` frames, 17 ms apart.
    func frames(_ count: Int) {
        for _ in 0..<count {
            clock.now += 17_000_000
            timestamp += 1.0 / 60
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    func stop() { keeper.deactivate() }
}

/// A clock the rig moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class QueueClock {
    var now: UInt64 = 1_000_000_000
}

/// What a queued closure captures, so a weak reference proves the closure was released.
@MainActor
private final class QueueProbe {
    private(set) var touches = 0
    func touch() { touches += 1 }
}

@MainActor
private final class QueueFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
