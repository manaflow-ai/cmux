import CmuxNextSettings
import Testing

/// `agents.memory.enabled`: the Agent Memory app's search uses the agent memory
/// index only when the key is `true`, nested or as one flat key, as the
/// `optchat-chief agent-memory` settings reader accepts it.
struct AgentMemoryEnabledSettingTests {
    private static func snapshot(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnset() {
        #expect(!Self.snapshot(.object([:])).agentMemoryEnabled)
    }

    @Test func onWhenTheNestedOrFlatKeyIsTrue() {
        #expect(Self.snapshot(.object(["agents": .object(["memory": .object(["enabled": .bool(true)])])])).agentMemoryEnabled)
        #expect(Self.snapshot(.object(["agents.memory.enabled": .bool(true)])).agentMemoryEnabled)
    }

    @Test(arguments: [JSONValue.bool(false), .string("true"), .number(1), .null, .object([:])])
    func onlyTrueTurnsItOn(value: JSONValue) {
        #expect(!Self.snapshot(.object(["agents": .object(["memory": .object(["enabled": value])])])).agentMemoryEnabled)
        #expect(!Self.snapshot(.object(["agents.memory.enabled": value])).agentMemoryEnabled)
    }

    @Test func theFlatKeyWinsAsInTheIndexTool() {
        let root: JSONValue = .object([
            "agents.memory.enabled": .bool(false),
            "agents": .object(["memory": .object(["enabled": .bool(true)])]),
        ])
        #expect(!Self.snapshot(root).agentMemoryEnabled)
    }
}
