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
}
