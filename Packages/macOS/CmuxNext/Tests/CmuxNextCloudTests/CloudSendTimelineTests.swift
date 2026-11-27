import CmuxNextCloud
import os
import Testing

/// A composer Cloud send's one line from the Send to the agent's first token (cmux#45953): each step's own time, adding
/// up to the span, and whether the span met the 3 s target and which step took the most when it did not.
@Suite struct CloudSendTimelineTests {
    /// A clock the test moves by hand, read from any thread as the timeline's is.
    private final class TestClock: Sendable {
        private let instant = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        var now: @Sendable () -> ContinuousClock.Instant { { [instant] in instant.withLock { $0 } } }
        func advance(_ ms: Int) { instant.withLock { $0 += .milliseconds(ms) } }
    }

    @Test func theStepsAddUpToTheSpanAndTheFirstTokenEndsIt() {
        let clock = TestClock()
        let timeline = CloudSendTimeline(now: clock.now)
        for (step, ms) in [("preflight", 40), ("machine", 300), ("copy", 900), ("approvals", 0), ("gateway", 0), ("open", 200),
                           ("page", 150), ("prompt", 350), ("start", 120)] {
            clock.advance(ms)
            #expect(timeline.mark(step) == nil)
        }
        clock.advance(700)
        let line = timeline.mark(CloudSendTimeline.firstToken)
        #expect(line == "cloud send to first token: 2760 ms; preflight 40, machine 300, copy 900, approvals 0, gateway 0, open 200, "
            + "page 150, prompt 350, start 120, first token 700; met the 3000 ms target")
        let steps = CloudSendTimeline.steps(timeline.marks)
        #expect(steps.map(\.ms).reduce(0, +) == timeline.marks.last?.at)
        // Ended: nothing more is marked, and a step marked twice kept its first end.
        clock.advance(5)
        #expect(timeline.finished)
        #expect(timeline.mark("late") == nil)
        #expect(timeline.marks.count == 10)
    }

    /// cmux#55519: the composer start opens the chat's workspace and tab, trusts the copy and warms its agent beside this
    /// Mac's gateway coming up, and waits for it only after `open`, just before the page's first prompt. RED before: the
    /// gateway was awaited after the approvals, so a gateway still coming up held the open and everything after it.
    @MainActor @Test func theOpenRunsBesideTheGatewayWhichIsAwaitedOnlyBeforeTheFirstPrompt() async {
        for (outlasts, gatewayMs) in [(false, 0), (true, 300)] {
            let clock = TestClock()
            let timeline = CloudSendTimeline(now: clock.now)
            let (began, beginning) = AsyncStream<Void>.makeStream()
            let (released, release) = AsyncStream<Void>.makeStream()
            let gateway = CloudStartBeside { () async -> Bool in
                beginning.yield()
                for await _ in released { return true }
                return false
            }
            for await _ in began { break } // it began with the start, before any step below
            for (step, ms) in [("machine", 2000), ("copy", 900), ("approvals", 0)] { clock.advance(ms); timeline.mark(step) }
            clock.advance(1500) // the workspace, the tab, the trust and the prewarm, while the gateway comes up
            if !outlasts { release.yield() }
            timeline.mark("open")
            if outlasts { clock.advance(300); release.yield() }
            #expect(await gateway.value)
            timeline.mark("gateway")
            #expect(timeline.marks.map(\.step) == ["machine", "copy", "approvals", "open", "gateway"])
            #expect(CloudSendTimeline.steps(timeline.marks).map(\.ms) == [2000, 900, 0, 1500, gatewayMs]) // the open never waits on it
        }
    }

    @Test func aStepMarkedTwiceKeepsItsFirstEnd() {
        let clock = TestClock()
        let timeline = CloudSendTimeline(now: clock.now)
        clock.advance(100)
        timeline.mark("prompt")
        clock.advance(900)
        timeline.mark("prompt")
        #expect(timeline.marks.map(\.at) == [100])
    }

    /// Over the target it says by how much and which step took the most, and the machine's own phases of the start.
    @Test func aSpanOverTheTargetNamesItsLargestStepAndTheMachinesPhases() {
        let marks = [("machine", 9_000), ("copy", 12_000), ("start", 15_500), ("first token", 17_000)].map { (step: $0.0, at: $0.1) }
        let line = CloudSendTimeline.line(marks, machine: ["session_new": 3400, "checks": 12, "total": 3500])
        #expect(line == "cloud send to first token: 17000 ms; machine 9000, copy 3000, start 3500, first token 1500; "
            + "machine checks 12, session_new 3400; over the 3000 ms target by 14000 ms, most in machine (9000 ms)")
    }

    /// Steps that ended together (approvals beside the copy) are 0 ms, never negative.
    @Test func aStepThatEndedBesideTheOneBeforeIsZero() {
        let marks = [("copy", 500), ("approvals", 400)].map { (step: $0.0, at: $0.1) }
        #expect(CloudSendTimeline.steps(marks).map(\.ms) == [500, 0])
    }

    /// The chat's tab finds its send's timeline under its creation key and its store id, marks on it, and the first token
    /// ends it there; an unknown tab marks nothing, and at most `kept` tabs are held.
    @Test func theChatsTabMarksOnItsSendsTimelineUntilTheFirstToken() {
        let timelines = CloudSendTimelines(), timeline = CloudSendTimeline()
        timelines.bind(timeline, machine: "m1", tabs: ["mutation-key", "tab-id", "tab-id"])
        timelines.mark("prompt", machine: "m1", tab: "tab-id")
        timelines.mark("start", machine: "m1", tab: "mutation-key", phases: ["session_new": 15])
        timelines.mark("prompt", machine: "m2", tab: "tab-id")
        #expect(timeline.marks.map(\.step) == ["prompt", "start"])
        timelines.mark(CloudSendTimeline.firstToken, machine: "m1", tab: "tab-id")
        #expect(timeline.finished)
        #expect(timeline.marks.map(\.step) == ["prompt", "start", "first token"])
        #expect(timelines.timeline(machine: "m1", tab: "tab-id") == nil)
        #expect(timelines.timeline(machine: "m1", tab: "mutation-key") == nil)
        for index in 0..<(CloudSendTimelines.kept + 4) { timelines.bind(CloudSendTimeline(), machine: "m", tabs: ["t\(index)"]) }
        #expect(timelines.timeline(machine: "m", tab: "t0") == nil)
        #expect(timelines.timeline(machine: "m", tab: "t\(CloudSendTimelines.kept + 3)") != nil)
    }
}

/// The composer send's agent prewarm names what the chat's page's first send will start (cmux#45953), in the copied
/// folder; nothing for a daemon that does not serve it or no absolute folder there.
@Suite struct CloudAgentPrewarmTests {
    @Test func aPrewarmNamesTheStartsAgentInTheCopiedFolder() throws {
        let prewarm = try #require(CloudAgentPrewarm(cwd: "/home/cmux/chats/app-1", harness: "claude", model: "claude-sonnet-4-5", mode: "default", served: true))
        #expect(prewarm == CloudAgentPrewarm(cwd: "/home/cmux/chats/app-1", harness: "claude", model: "claude-sonnet-4-5", mode: "default", served: true))
        #expect((prewarm.cwd, prewarm.harness, prewarm.model, prewarm.mode) == ("/home/cmux/chats/app-1", "claude", "claude-sonnet-4-5", "default"))
    }

    @Test func nothingIsWarmedWithoutTheVerbOrAFolderThere() {
        #expect(CloudAgentPrewarm(cwd: "/home/cmux/chats/app-1", harness: "claude", model: nil, mode: nil, served: false) == nil)
        #expect(CloudAgentPrewarm(cwd: nil, harness: "claude", model: nil, mode: nil, served: true) == nil)
        #expect(CloudAgentPrewarm(cwd: "chats/app-1", harness: "claude", model: nil, mode: nil, served: true) == nil)
        #expect(CloudAgentPrewarm(cwd: "chats/app-1", harness: "claude", model: nil, mode: nil, served: true, servesChatFolder: true) == nil)
    }

    /// A start with no folder (`cloud start-session` with no `--cwd`, a chat with no project) runs in the chat's own
    /// `~/chats/<id>`; a daemon that serves the chat folder prewarm makes it and warms the agent there.
    @Test func aNoFolderStartIsWarmedInTheChatsOwnFolderWhereServed() throws {
        let prewarm = try #require(CloudAgentPrewarm(cwd: nil, harness: "claude", model: nil, mode: nil, served: true, servesChatFolder: true))
        #expect(prewarm.cwd == nil && prewarm.harness == "claude")
        #expect(CloudAgentPrewarm(cwd: nil, harness: "claude", model: nil, mode: nil, served: false, servesChatFolder: true) == nil)
    }
}
