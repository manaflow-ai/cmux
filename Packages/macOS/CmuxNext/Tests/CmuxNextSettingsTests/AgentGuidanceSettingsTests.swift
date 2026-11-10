import CmuxNextSettings
import Testing

/// `agents.guidance.*`: every switch is on by default, and each turns off on its own, as the
/// acpmux daemon reads them when it creates a chat (`agent_guidance.rs`).
struct AgentGuidanceSettingsTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func allOnByDefault() {
        let settings = Self.snapshot(.object([:])).agentGuidance
        #expect(settings.claude && settings.codex && settings.otherAgents && settings.userSkills)
    }

    @Test func eachSwitchTurnsOffAlone() {
        let root: JSONValue = .object([
            "agents": .object(["guidance": .object(["codex": .bool(false), "userSkills": .bool(false)])]),
        ])
        let settings = Self.snapshot(root).agentGuidance
        #expect(settings.claude && !settings.codex && settings.otherAgents && !settings.userSkills)
    }

    @Test func everyKeyIsInTheSchema() {
        let keys = Set(SettingsSchema.all.map(\.id))
        for key in ["agents.guidance.claude", "agents.guidance.codex", "agents.guidance.otherAgents", "agents.guidance.userSkills"] {
            #expect(keys.contains(key), "\(key)")
        }
    }
}
