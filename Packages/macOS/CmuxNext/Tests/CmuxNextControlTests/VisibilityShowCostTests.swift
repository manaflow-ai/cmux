import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The show order and warm votes (plans/cmux-next/chrome-parity/p06-scheduler.md, task 213): a show
/// re-reads in its own turn only what is on screen in the focused pane (and `firstFrame`
/// observations); the rest re-read as userBlocking tasks in viewport rank order within two frames,
/// and a warm hidden node's observers read in idle time so its show reads nothing.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VisibilityShowCostTests {
    /// The acceptance case: 12 panes (the focused one on screen) and 400 row observers.
    @Test func aWorkspaceOfTwelvePanesAndFourHundredRowsReadsOnlyTheFocusedPaneInTheShowTurn() {
        let rig = ShowRig(keepFrames: true)
        let workspace = VisibilityNode("workspace", own: .hidden, parent: rig.window)
        var watches: [VisibleObservation<Int>] = []
        for pane in 0..<12 {
            let paneNode = VisibilityNode("pane:\(pane)", parent: workspace)
            // Pane 0 is focused: it keeps the default, in the show turn.
            if pane > 0 { paneNode.showOrder = .afterShow(rank: pane) }
            let tab = VisibilityNode("tab:\(pane)", parent: paneNode)
            for _ in 0..<3 { watches.append(rig.watch(tab, owner: pane == 0 ? "test.focused" : "test.pane", rank: pane)) }
        }
        let sidebar = VisibilityNode("sidebar", parent: workspace)
        // Built in reverse, so the ranks, not the build order, decide the order.
        for row in (0..<400).reversed() {
            let rowNode = VisibilityNode("row:\(row)", parent: sidebar)
            rowNode.showOrder = .afterShow(rank: 100 + row)
            watches.append(rig.watch(rowNode, owner: "test.row", rank: 100 + row))
        }
        rig.resetCounts()
        rig.model.value = 1
        #expect(rig.reads.isEmpty, "a hidden observer read")

        workspace.set(.visible)
        #expect(rig.reads == [0, 0, 0], "the show turn read \(rig.reads.count) observers, not the focused pane's 3")
        #expect(rig.applied == [1, 1, 1])
        #expect(rig.showRereads("test.focused") == 3)
        #expect(rig.showRereads("test.row") == 0)

        rig.runTurns()
        for _ in 0..<2 where rig.reads.count < watches.count { rig.frame() }
        #expect(rig.reads.count == watches.count, "\(watches.count - rig.reads.count) observers had not read after 2 frames")
        #expect(rig.reads == rig.reads.sorted(), "the userBlocking re-reads did not run in rank order")
        #expect(rig.applied.count == watches.count)
        #expect(rig.applied.allSatisfy { $0 == 1 })
        #expect(rig.showRereads("test.pane") == 33)
        #expect(rig.showRereads("test.row") == 400)

        // Every observer tracks again after its show.
        rig.resetCounts()
        rig.model.value = 2
        rig.runTurns()
        for _ in 0..<3 where rig.applied.count < watches.count { rig.frame() }
        #expect(rig.applied.count == watches.count)
        rig.stop(watches)
    }

    /// A `firstFrame` observation under a node that shows after the pass reads in the show turn.
    @Test func aFirstFrameObservationReadsInTheShowTurnWhateverItsNodeOrder() {
        let rig = ShowRig(keepFrames: true)
        let workspace = VisibilityNode("workspace", own: .hidden, parent: rig.window)
        workspace.showOrder = .afterShow(rank: 5)
        let gate = rig.watch(workspace, owner: "test.firstFrame", rank: 1, firstFrame: true)
        let rest = rig.watch(workspace, owner: "test.rest", rank: 5)
        rig.resetCounts()
        rig.model.value = 1
        workspace.set(.visible)
        #expect(rig.reads == [1])
        rig.runTurns()
        rig.frame()
        #expect(rig.reads == [1, 5])
        rig.stop([gate, rest])
    }

    /// Hidden again before its userBlocking task runs: the task reads nothing, and the next show
    /// reads once.
    @Test func aShowUndoneBeforeItsTaskRunsReadsNothing() {
        let rig = ShowRig(keepFrames: true)
        let workspace = VisibilityNode("workspace", own: .hidden, parent: rig.window)
        let row = VisibilityNode("row", parent: workspace)
        row.showOrder = .afterShow(rank: 0)
        let watch = rig.watch(row, owner: "test.row", rank: 0)
        rig.resetCounts()
        workspace.set(.visible)
        workspace.set(.hidden)
        rig.model.value = 1
        rig.runTurns()
        rig.frame()
        rig.frame()
        #expect(rig.reads.isEmpty, "a hidden row read \(rig.reads.count) times")
        workspace.set(.visible)
        rig.runTurns()
        rig.frame()
        #expect(rig.reads == [0])
        #expect(rig.applied == [1])
        rig.stop([watch])
    }

    /// A node's show order follows its nearest ancestor that has one; the default is the show turn.
    @Test func theShowOrderFollowsTheNearestAncestor() {
        let window = VisibilityNode(root: "window", own: .visible)
        let pane = VisibilityNode("pane", parent: window)
        let tab = VisibilityNode("tab", parent: pane)
        #expect(tab.resolvedShowOrder == .inShowTurn)
        pane.showOrder = .afterShow(rank: 3)
        #expect(tab.resolvedShowOrder == .afterShow(rank: 3))
        tab.showOrder = .inShowTurn
        #expect(tab.resolvedShowOrder == .inShowTurn)
    }

    // MARK: Warm votes

    /// A warm hidden node reads once in idle time, applies nothing, and its show applies that value
    /// with no read.
    @Test func aWarmHiddenNodeReadsInIdleTimeAndItsShowReadsNothing() {
        let rig = ShowRig(keepFrames: false)
        let tab = VisibilityNode("tab", own: .hidden, parent: rig.window)
        let watch = rig.watch(tab, owner: "test.warm", rank: 0)
        rig.resetCounts()
        rig.model.value = 1
        let vote = tab.warmVote(reason: "hover")
        #expect(tab.isWarm)
        #expect(rig.reads.isEmpty, "a warm read never runs inline")
        rig.idleTimer.run(ms: 200)
        #expect(rig.reads == [0], "the warm read ran \(rig.reads.count) times in idle time")
        #expect(rig.applied.isEmpty, "a warm read applied to a hidden view")
        tab.set(.visible)
        #expect(rig.reads == [0], "the show of a warm node read again")
        #expect(rig.applied == [1])
        #expect(rig.showRereads("test.warm") == 0)
        vote.release()
        rig.stop([watch])
    }

    /// A change after the warm read makes it read again in idle time; the show still reads nothing.
    @Test func aChangeAfterTheWarmReadReadsAgainInIdleTime() {
        let rig = ShowRig(keepFrames: false)
        let tab = VisibilityNode("tab", own: .hidden, parent: rig.window)
        let watch = rig.watch(tab, owner: "test.warm", rank: 0)
        let vote = tab.warmVote(reason: "ctrl-tab")
        rig.idleTimer.run(ms: 200)
        rig.resetCounts()
        rig.model.value = 2
        // The tracking re-arms in the change's turn, as a visible observer's does.
        #expect(rig.reads == [0])
        rig.idleTimer.run(ms: 200)
        #expect(rig.reads == [0, 0])
        #expect(rig.applied.isEmpty)
        tab.set(.visible)
        #expect(rig.reads == [0, 0])
        #expect(rig.applied == [2])
        vote.release()
        rig.stop([watch])
    }

    /// The last release while hidden drops the warm tracking: later changes reach nothing.
    @Test func releasingTheWarmVoteDropsTheTracking() {
        let rig = ShowRig(keepFrames: false)
        let tab = VisibilityNode("tab", own: .hidden, parent: rig.window)
        let watch = rig.watch(tab, owner: "test.warm", rank: 0)
        let vote = tab.warmVote(reason: "neighbor")
        rig.idleTimer.run(ms: 200)
        #expect(rig.armed("test.warm") == 1)
        vote.release()
        #expect(!tab.isWarm)
        #expect(rig.armed("test.warm") == 0)
        rig.resetCounts()
        for value in 1...10 { rig.model.value = value }
        rig.idleTimer.run(ms: 200)
        #expect(rig.reads.isEmpty, "a cold hidden observer read \(rig.reads.count) times")
        tab.set(.visible)
        #expect(rig.reads == [0], "the show of a cold node reads once")
        #expect(rig.applied == [10])
        rig.stop([watch])
    }

    /// A warm vote reaches the subtree a capture would (not own-hidden children), with one notice
    /// per change.
    @Test func aWarmVoteReachesTheShownSubtreeOnce() {
        let window = VisibilityNode(root: "window", own: .visible)
        let workspace = VisibilityNode("workspace", own: .hidden, parent: window)
        let pane = VisibilityNode("pane", parent: workspace)
        let unselected = VisibilityNode("tab", own: .hidden, parent: pane)
        var notices: [Bool] = []
        let token = pane.subscribeWarm(owner: "test") { notices.append($0) }
        let first = workspace.warmVote(reason: "ctrl-tab")
        let second = workspace.warmVote(reason: "hover")
        #expect(pane.isWarm)
        #expect(!unselected.isWarm, "an unselected tab inherited the warm vote")
        #expect(workspace.warmReasons == ["ctrl-tab", "hover"])
        first.release()
        #expect(pane.isWarm)
        second.release()
        second.release()
        #expect(!pane.isWarm)
        #expect(notices == [true, false])
        #expect(workspace.effective == .hidden, "a warm vote changed what a person sees")
        token.cancel()
    }
}

// MARK: Fixtures

/// The observed model.
@MainActor @Observable
private final class ShowModel {
    var value = 0
}

/// A scheduler on a fake link with hand-run turns, frames and idle periods, a visible window root,
/// and the reads and applies of every observation, each read recorded by its observation's rank.
@MainActor
private final class ShowRig {
    let model = ShowModel()
    let clock: ShowClock
    let idleTimer: ShowIdleTimer
    let window = VisibilityNode(root: "window", own: .visible)
    let work: MainWorkScheduler
    private let turns: ShowTurns
    private let keeper: FrameClient?
    private(set) var reads: [Int] = []
    private(set) var applied: [Int] = []
    private var timestamp: Double = 0

    init(keepFrames: Bool) {
        let clock = ShowClock(), turns = ShowTurns(), idleTimer = ShowIdleTimer(clock: clock)
        self.clock = clock
        self.turns = turns
        self.idleTimer = idleTimer
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: ShowInput(), uptimeNanos: clock.read),
                                         performTurn: { turns.add($0) }, idleTimer: idleTimer) { _ in ShowFrameLink() }
        if keepFrames {
            let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
            keeper.activate()
            self.keeper = keeper
        } else {
            keeper = nil
        }
    }

    /// Observes `model.value` under `node`; each read costs 2 µs of the fake clock.
    func watch(_ node: VisibilityNode, owner: String, rank: Int, firstFrame: Bool = false) -> VisibleObservation<Int> {
        VisibleObservation(node, owner: owner, on: work, firstFrame: firstFrame) { [self] in
            reads.append(rank)
            clock.advance(ms: 0.002)
            return model.value
        } apply: { [self] value in
            applied.append(value)
        }
    }

    func resetCounts() {
        reads = []
        applied = []
    }

    func showRereads(_ owner: String) -> UInt64 {
        work.observations.snapshot(matching: owner).first { $0.owner == owner }?.showRereads ?? 0
    }

    func armed(_ owner: String) -> Int {
        work.observations.snapshot(matching: owner).first { $0.owner == owner }?.armed ?? 0
    }

    /// Runs the run loop turns the posts queued, and the ones those queued.
    func runTurns() {
        while let turn = turns.next() { turn() }
    }

    /// One display frame, 17 ms after the last one.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    func stop(_ watches: [VisibleObservation<Int>]) {
        for watch in watches { watch.cancel() }
        keeper?.deactivate()
    }
}

/// The run loop turns the scheduler queued, run by the test.
@MainActor
private final class ShowTurns {
    private var queued: [@MainActor () -> Void] = []

    func add(_ turn: @escaping @MainActor () -> Void) { queued.append(turn) }

    func next() -> (@MainActor () -> Void)? {
        queued.isEmpty ? nil : queued.removeFirst()
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ShowClock {
    var now: UInt64 = 10_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

/// The idle period timer, fired by moving the clock.
@MainActor
private final class ShowIdleTimer: IdlePeriodTimer {
    private let clock: ShowClock
    private var fire: (@MainActor () -> Void)?
    private var fireAt: UInt64?

    init(clock: ShowClock) { self.clock = clock }

    func arm(afterNanos delay: UInt64, _ fire: @escaping @MainActor () -> Void) {
        fireAt = clock.now + delay
        self.fire = fire
    }

    func cancel() {
        fireAt = nil
        fire = nil
    }

    /// Moves the clock `ms` on, firing the timer at each due time on the way.
    func run(ms: Double) {
        let end = clock.now + UInt64(ms * 1_000_000)
        while let at = fireAt, at <= end, let pending = fire {
            clock.now = max(clock.now, at)
            fireAt = nil
            fire = nil
            pending()
        }
        clock.now = max(clock.now, end)
    }
}

@MainActor
private final class ShowInput: InputPendingSource {
    func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}

@MainActor
private final class ShowFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
