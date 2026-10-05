import Testing
@testable import CmuxAgentJournal

@Suite("Replay policy")
struct AgentJournalReplayPolicyTests {
    private let policy = AgentJournalReplayPolicy()
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"

    @Test func startupKeepsOnlyBlockedStates() {
        let snapshot = AgentLifecycleSnapshot(
            phases: [
                surface: [
                    "claude_code": .needsInput,
                    "codex": .running,
                    "grok": .idle,
                    "gemini": .error,
                    "kimi": .unknown,
                ],
            ],
            newestOccurredAtMs: [
                surface: [
                    "claude_code": 10, "codex": 20, "grok": 30, "gemini": 40, "kimi": 50,
                ],
            ]
        )
        let startup = policy.startupSnapshot(from: snapshot)
        #expect(startup.phases == [
            surface: ["claude_code": .needsInput, "gemini": .error],
        ])
        #expect(startup.newestOccurredAtMs[surface]?["claude_code"] == 10)
        #expect(startup.newestOccurredAtMs[surface]?["gemini"] == 40)
    }

    @Test func startupOfEmptySnapshotIsEmpty() {
        let startup = policy.startupSnapshot(from: AgentLifecycleSnapshot())
        #expect(startup.phases.isEmpty)
    }

    @Test(arguments: [AgentSessionActivity.working, .idle, .waiting, .paused, .ended])
    func startupNeverRestoresHistoricalWorkBehindPendingAttention(activity: AgentSessionActivity) {
        let saved = AgentSessionLifecycleState(phase: .needsInput, ended: activity == .ended,
            lastSequence: 8, lastOccurredAtMs: 800, activity: activity, reason: .question,
            mode: .plan, modeSequence: 2, activityObservedAtMs: 800, transitionedAtMs: 700,
            modeObservedAtMs: 200, processGeneration: 77, modeProcessGeneration: 77,
            pendingUserActionCount: 2, pendingUserActionSequence: 6,
            pendingUserActionsObservedAtMs: 600, pendingUserActionsProcessGeneration: 77)
        let replay = policy.startupRuntimeState(from: saved)
        #expect(replay.activity == .unknown)
        #expect(replay.phase == .unknown)
        #expect(!replay.ended)
        #expect(replay.activityObservedAtMs == nil)
        #expect(replay.transitionedAtMs == nil)
        #expect(replay.mode == .plan)
        #expect(replay.modeObservedAtMs == 200)
        #expect(replay.pendingUserActionCount == 2)
        #expect(replay.pendingUserActionsObservedAtMs == 600)
    }

    @Test(arguments: [AgentSessionActivity.needsInput, .failed, .quotaBlocked])
    func startupPreservesOriginalBlockedEvidence(activity: AgentSessionActivity) {
        let saved = AgentSessionLifecycleState(phase: .needsInput, ended: false, lastSequence: 2,
            lastOccurredAtMs: 200, activity: activity, activityObservedAtMs: 200, processGeneration: 77)
        #expect(policy.startupRuntimeState(from: saved) == saved)
    }
}
