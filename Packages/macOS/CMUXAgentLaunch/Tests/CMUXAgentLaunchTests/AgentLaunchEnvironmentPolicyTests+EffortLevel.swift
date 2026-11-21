import CMUXAgentLaunch
import Testing

extension AgentLaunchEnvironmentPolicyTests {
    @Test func recordsAKnownEffortLevel() {
        #expect(
            AgentLaunchEnvironmentPolicy().sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "xhigh") == "xhigh"
        )
    }

    @Test func dropsAnUnknownEffortLevel() {
        let policy = AgentLaunchEnvironmentPolicy()
        #expect(policy.sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "auto") == nil)
        #expect(policy.sanitizedValue(key: "CLAUDE_CODE_EFFORT_LEVEL", value: "high; echo") == nil)
    }

    @Test func selectedEnvironmentKeepsTheEffortLevel() {
        let env = ["CLAUDE_CODE_EFFORT_LEVEL": "low", "FOO": "1"]
        let selected = AgentLaunchEnvironmentPolicy().selectedEnvironment(from: env, kind: "claude")
        #expect(selected["CLAUDE_CODE_EFFORT_LEVEL"] == "low")
    }

    /// cmux's session priority resume marks the level it set, so a later look at the recorded
    /// launch can tell it from a level the user set. The marker takes the same five values.
    @Test func recordsTheSessionPriorityMarkerWithTheSameValues() {
        let policy = AgentLaunchEnvironmentPolicy()
        for level in ClaudeEffortLevel.allCases {
            #expect(policy.sanitizedValue(key: ClaudeEffortLevel.sessionPriorityMarkerKey, value: level.rawValue) == level.rawValue)
        }
        #expect(policy.sanitizedValue(key: ClaudeEffortLevel.sessionPriorityMarkerKey, value: "auto") == nil)
        #expect(policy.sanitizedValue(key: ClaudeEffortLevel.sessionPriorityMarkerKey, value: "high; echo") == nil)
        #expect(policy.inputEnvironmentKeys.contains(ClaudeEffortLevel.sessionPriorityMarkerKey))
    }

    @Test(arguments: ["claude", "Claude", "claudeteams"])
    func effortKeysAreRecordedAndReplayedForClaude(kind: String) {
        let env = [
            ClaudeEffortLevel.environmentKey: "high",
            ClaudeEffortLevel.sessionPriorityMarkerKey: "high",
        ]
        let policy = AgentLaunchEnvironmentPolicy()

        #expect(policy.selectedEnvironment(from: env, kind: kind) == env)
        #expect(policy.selectedReplayEnvironment(from: env, kind: kind, launcher: nil, arguments: []) == env)
    }

    /// Another agent never records or replays Claude's effort, like `CURSOR_CONFIG_DIR` is
    /// Cursor's alone.
    @Test(arguments: [nil, "codex", "cursor", "opencode", "pi"] as [String?])
    func effortKeysStayScopedToClaude(kind: String?) {
        let env = [
            ClaudeEffortLevel.environmentKey: "high",
            ClaudeEffortLevel.sessionPriorityMarkerKey: "high",
        ]
        let policy = AgentLaunchEnvironmentPolicy()

        #expect(policy.selectedEnvironment(from: env, kind: kind).isEmpty)
        #expect(policy.selectedRestoreEnvironment(from: env, kind: kind).isEmpty)
        #expect(policy.selectedReplayEnvironment(from: env, kind: kind, launcher: nil, arguments: []).isEmpty)
    }
}
