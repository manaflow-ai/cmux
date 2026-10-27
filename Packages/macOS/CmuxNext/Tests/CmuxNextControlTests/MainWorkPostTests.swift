import CmuxNextWakeups
import Foundation
import Testing

/// The main-thread scheduler's posting API (plans/cmux-next/chrome-parity/p06-scheduler.md, task 001):
/// `post` by class and owner, the first post after idle on the next turn, `apply`, and the
/// PostTaskAndReply form `BackgroundWork.run { }.reply(on:class:owner:)`, with `posted_from` on the board.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainWorkPostTests {
    /// Classes posted in reverse run in class order in one frame (Chrome's TaskQueueSelector:
    /// the highest priority queue first).
    @Test func classesPostedInReverseRunInClassOrderInOneFrame() {
        let clock = PostClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in PostFakeLink() }
        let keeper = LinkKeeper(on: work)
        var ran: [String] = []
        work.post(.background, owner: "b") { ran.append("background") }
        work.post(.automation, owner: "a") { ran.append("automation") }
        work.post(.visible, owner: "v") { ran.append("visible") }
        #expect(ran.isEmpty, "a post never runs inline")
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == ["visible", "automation", "background"])
        #expect(work.postedCount(.visible) + work.postedCount(.automation) + work.postedCount(.background) == 0)
        keeper.stop()
    }

    /// Pending input holds a post until the input clears, and a class that yielded one frame runs
    /// on the next one even while input is still pending (typing never starves it).
    @Test func pendingInputDefersAPostUntilInputClearsOrTheProgressRuleApplies() {
        let clock = PostClock()
        let input = PostFakeInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in PostFakeLink() }
        let keeper = LinkKeeper(on: work)
        var ran: [String] = []
        input.pending = true
        work.post(.automation, owner: "cli.first") { ran.append("first") }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran.isEmpty, "the post ran ahead of the person's pending key")
        input.pending = false
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ran == ["first"], "the input cleared: the post runs")

        input.pending = true
        clock.advance(ms: 17)
        work.post(.automation, owner: "cli.second") { ran.append("second") }
        work.frameDidFire(timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(ran == ["first"])
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 4, refreshInterval: 1.0 / 60)
        #expect(ran == ["first", "second"], "it yielded last frame: it runs this frame though the key is still pending")
        keeper.stop()
    }

    /// The first post on an idle scheduler runs on the next main run loop turn, before any frame;
    /// with input pending it waits for frames instead.
    @Test func theFirstPostOnAnIdleSchedulerRunsBeforeAnyFrame() {
        let clock = PostClock()
        let input = PostFakeInput()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in PostFakeLink() }
        var ran: [String] = []
        work.post(.automation, owner: "cli.request") { ran.append("automation") }
        work.post(.visible, owner: "store.batch") { ran.append("visible") }
        #expect(ran.isEmpty)
        spinMainRunLoop(until: { ran.count == 2 })
        #expect(ran == ["visible", "automation"], "one turn runs the posts in class order")
        #expect(work.frames.frames == 0, "it waited for a frame")
        #expect(!work.frames.hasLink, "nothing left: no display link")

        input.pending = true
        clock.advance(ms: 17)
        work.post(.automation, owner: "cli.request") { ran.append("held") }
        spinMainRunLoop(until: { work.frames.hasLink })
        #expect(ran.count == 2, "the turn ran a post ahead of pending input")
        #expect(work.frames.hasLink, "the held post waits for frames")
        input.pending = false
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran.last == "held")
    }

    /// While frames run (another client keeps the link up), an automation post runs on the next
    /// run loop turn, not on the next frame: a request waits for its reply, and Chrome runs the next
    /// runnable task on the next pump iteration. Pending input holds it for a frame; visible work
    /// still waits for the frame that shows it.
    @Test func anAutomationPostWhileFramesRunRunsOnTheNextTurn() {
        let clock = PostClock()
        let input = PostFakeInput()
        let turns = PostTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read),
                                             performTurn: turns.perform) { _ in PostFakeLink() }
        let keeper = LinkKeeper(on: work)
        var ran: [String] = []
        work.post(.visible, owner: "sidebar.rows") { ran.append("visible") }
        work.post(.automation, owner: "cli.request") { ran.append("automation") }
        #expect(ran.isEmpty, "a post never runs inline")
        #expect(turns.runAll() == 1, "the automation post queued one turn")
        #expect(ran == ["automation"], "the request waited for a display frame")
        #expect(work.frames.frames == 0)

        input.pending = true
        work.post(.automation, owner: "cli.request") { ran.append("held") }
        #expect(turns.runAll() == 1)
        #expect(ran == ["automation"], "the turn ran a request ahead of the person's pending key")
        input.pending = false
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ran == ["automation", "visible", "held"], "the frame runs the visible work and the held request")
        keeper.stop()
    }

    @Test func applyReturnsTheValue() async throws {
        let clock = PostClock()
        // Turns never run here: both posts wait for the hand-fired frame.
        let turns = PostTurns()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), performTurn: turns.perform) { _ in
            PostFakeLink()
        }
        let keeper = LinkKeeper(on: work)
        let value = Task { @MainActor in await work.apply(.visible, owner: "pages.title") { 42 } }
        let failure = Task { @MainActor in
            try await work.apply(.automation, owner: "pages.fail") { () throws(PostFailure) -> Int in throw PostFailure.refused }
        }
        while work.postedCount(.visible) + work.postedCount(.automation) < 2 { await Task.yield() }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(await value.value == 42)
        await #expect(throws: PostFailure.refused) { try await failure.value }
        keeper.stop()
    }

    /// PostTaskAndReply: off-main work's result runs on main as a task of its class, and the board
    /// names the reply's posting file and line.
    @Test func aReplyRunsInItsClassAndRecordsWhereItWasPosted() {
        let clock = PostClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in PostFakeLink() }
        let background = BackgroundWork(cpuWidth: 1, label: "MainWorkPostTests")
        let reply = ReplySeen()
        let line: UInt = #line + 1
        background.run(.userVisible, mayBlock: .cpu) { 6 * 7 }.reply(on: work, class: .automation, owner: "preview.load") { value in
            reply.seen = (value, work.board.running, Thread.isMainThread)
        }
        spinMainRunLoop(until: { reply.seen != nil })
        let seen = reply.seen
        #expect(seen?.value == 42)
        #expect(seen?.isMain == true)
        #expect(seen?.task?.workClass == .automation)
        #expect(seen?.task?.owner == "preview.load")
        #expect(seen?.task?.postedFrom == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainWorkPostTests.swift", line: line))
        #expect(work.board.running == nil)
    }

    /// A plain post records its site too.
    @Test func aPostRecordsItsFileAndLine() {
        let clock = PostClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in PostFakeLink() }
        let keeper = LinkKeeper(on: work)
        var site: MainTaskBoard.PostedFrom?
        let line: UInt = #line + 1
        work.post(.visible, owner: "sidebar.rows") { site = work.board.running?.postedFrom }
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(site == MainTaskBoard.PostedFrom(file: "CmuxNextControlTests/MainWorkPostTests.swift", line: line))
        keeper.stop()
    }

    /// Runs main run loop passes (not main-queue jobs) until `done` or 5 s.
    private func spinMainRunLoop(until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }
}

/// What the reply saw (a `@Sendable` reply cannot write a captured local).
@MainActor
private final class ReplySeen {
    var seen: (value: Int, task: MainTaskBoard.Task?, isMain: Bool)?
}

private enum PostFailure: Error, Equatable {
    case refused
}

/// The scheduler's run loop turns, run only when the test says (``MainWorkScheduler/TurnPerformer``).
@MainActor
private final class PostTurns {
    private var queued: [@MainActor () -> Void] = []

    var perform: MainWorkScheduler.TurnPerformer { { [weak self] turn in self?.queued.append(turn) } }

    /// Runs the turns queued now; returns how many ran.
    func runAll() -> Int {
        let turns = queued
        queued.removeAll()
        for turn in turns { turn() }
        return turns.count
    }
}

/// A frame-class client that keeps the scheduler's fake link up, so posts wait for hand-fired frames.
@MainActor
private final class LinkKeeper {
    private let client: FrameClient

    init(on work: MainWorkScheduler) {
        client = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        client.activate()
    }

    func stop() { client.deactivate() }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class PostClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class PostFakeInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class PostFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
