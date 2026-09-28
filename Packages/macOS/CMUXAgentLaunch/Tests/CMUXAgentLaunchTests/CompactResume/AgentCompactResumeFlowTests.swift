import Testing
@testable import CMUXAgentLaunch

@Suite("Compact and resume flow")
struct AgentCompactResumeFlowTests {
    private let compact = "/compact Keep the current task: fix the test; keep file paths, decisions and open TODOs."
    private let resume = "Continue where you left off. Current task: fix the test"

    private func flow(_ timing: AgentCompactResumeTiming) -> AgentCompactResumeFlow {
        AgentCompactResumeFlow(timing: timing, compactCommand: compact, resumePrompt: resume)
    }

    @Test func runningTurnIsInterruptedThenCompactedThenResumed() {
        var flow = flow(.now)
        #expect(flow.start(lifecycle: .running) { .empty } == [.interrupt])
        #expect(flow.phaseTimeout == AgentCompactResumeFlow.interruptedTurnTimeout)
        #expect(flow.lifecycleChanged(to: .idle) { .empty } == [.settle])
        #expect(flow.settled(lifecycle: .idle) { .empty } == [.send(compact)])
        #expect(flow.phase == .compacting)
        #expect(flow.lifecycleChanged(to: .idle) { .empty } == [], "Idle during compaction changes nothing")
        #expect(flow.compactionFinished(lifecycle: .idle) { .empty } == [.send(resume), .finish(.resumed)])
        #expect(flow.isFinished)
        #expect(flow.phaseTimeout == nil)
    }

    @Test func idleTimingWaitsForTheTurnWithoutInterrupting() {
        var flow = flow(.idle)
        #expect(flow.start(lifecycle: .running) { .empty } == [])
        #expect(flow.phaseTimeout == AgentCompactResumeFlow.naturalTurnTimeout)
        #expect(flow.lifecycleChanged(to: .blocked) { .empty } == [], "A permission prompt mid-turn is waited out")
        #expect(flow.lifecycleChanged(to: .running) { .empty } == [])
        #expect(flow.lifecycleChanged(to: .idle) { .empty } == [.send(compact)], "No settle without an interrupt")
    }

    @Test func idleAgentCompactsAtOnce() {
        var flow = flow(.now)
        #expect(flow.start(lifecycle: .idle) { .empty } == [.send(compact)])
        #expect(flow.phaseTimeout == AgentCompactResumeFlow.compactionTimeout)
    }

    @Test func interruptIsSentOnlyOnce() {
        var flow = flow(.now)
        #expect(flow.start(lifecycle: .running) { .empty } == [.interrupt])
        #expect(flow.lifecycleChanged(to: .running) { .empty } == [])
        #expect(flow.lifecycleChanged(to: .idle) { .empty } == [.settle])
        #expect(flow.settled(lifecycle: .running) { .empty } == [], "The agent kept working")
        #expect(flow.phase == .waitingForIdle)
        #expect(flow.lifecycleChanged(to: .idle) { .empty } == [.settle])
    }

    @Test func blockedOrMissingAgentIsRefusedAtStart() {
        var blocked = flow(.now)
        #expect(blocked.start(lifecycle: .blocked) { .empty } == [.finish(.stopped(.blocked))])
        var absent = flow(.now)
        #expect(absent.start(lifecycle: .absent) { .empty } == [.finish(.stopped(.noAgent))])
    }

    @Test func inputIsReadOnlyWhenTheAgentIsIdle() {
        var flow = flow(.idle)
        var reads = 0
        _ = flow.start(lifecycle: .running) { reads += 1; return .empty }
        _ = flow.lifecycleChanged(to: .blocked) { reads += 1; return .empty }
        #expect(reads == 0, "A dialog's screen is never classified as input")
    }

    @Test(arguments: [
        (AgentPromptInputState.hasText, AgentCompactResumeStopReason.inputNotEmpty),
        (.unknown, .inputUnreadable),
    ])
    func draftOrUnreadableInputIsNeverTypedInto(input: AgentPromptInputState, reason: AgentCompactResumeStopReason) {
        var atStart = flow(.now)
        #expect(atStart.start(lifecycle: .idle) { input } == [.finish(.stopped(reason))])

        var afterCompaction = flow(.now)
        _ = afterCompaction.start(lifecycle: .idle) { .empty }
        #expect(afterCompaction.compactionFinished(lifecycle: .idle) { input } == [.finish(.stopped(reason))])
    }

    @Test func compactionBeforeOurCommandIsIgnored() {
        var flow = flow(.idle)
        _ = flow.start(lifecycle: .running) { .empty }
        #expect(flow.compactionFinished(lifecycle: .running) { .empty } == [], "Claude's own auto-compaction mid-turn")
        #expect(flow.phase == .waitingForIdle)
    }

    @Test func dialogAfterCompactionStopsWithoutTyping() {
        var flow = flow(.now)
        _ = flow.start(lifecycle: .idle) { .empty }
        #expect(flow.compactionFinished(lifecycle: .blocked) { .empty } == [.finish(.stopped(.blocked))])
    }

    @Test func timeoutGivesUpQuietlyOnce() {
        var flow = flow(.now)
        _ = flow.start(lifecycle: .idle) { .empty }
        #expect(flow.timedOut() == [.finish(.stopped(.timedOut))])
        #expect(flow.timedOut() == [])
        #expect(flow.compactionFinished(lifecycle: .idle) { .empty } == [], "A late PostCompact types nothing")
    }

    @Test func agentLeavingMidRunStops() {
        var flow = flow(.now)
        _ = flow.start(lifecycle: .idle) { .empty }
        #expect(flow.lifecycleChanged(to: .absent) { .empty } == [.finish(.stopped(.agentExited))])
    }
}
