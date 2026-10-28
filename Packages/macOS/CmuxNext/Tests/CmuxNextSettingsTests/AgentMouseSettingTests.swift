import CmuxNextSettings
import Testing

/// `browser.agentMouse.motion` and `browser.agentMouse.maxMoveMs`
/// (plans/cmux-next/human-mouse-DESIGN.md): human motion with a 350 ms cap
/// unless the person picks otherwise; bad values keep the default and say why.
struct AgentMouseSettingTests {
    private func snapshot(_ mouse: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = mouse.map { .object(["browser": .object(["agentMouse": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func absentIsHumanMotionWithTheDefaultCap() {
        let value = snapshot(nil).browserAgentMouse
        #expect(value == AgentMouseSetting.Value(motion: .human, maxMoveMs: 350))
    }

    @Test func thePersonsChoiceIsRead() {
        let value = snapshot(.object(["motion": "instant", "maxMoveMs": 200])).browserAgentMouse
        #expect(value.motion == .instant)
        #expect(value.maxMoveMs == 200)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() {
        let parsed = snapshot(.object(["motion": "teleport", "maxMoveMs": 99_999]))
        #expect(parsed.browserAgentMouse == AgentMouseSetting.Value(motion: .human, maxMoveMs: 350))
        let paths = Set(parsed.diagnostics.map(\.path))
        #expect(paths.contains("browser.agentMouse.motion"))
        #expect(paths.contains("browser.agentMouse.maxMoveMs"))
    }

    @Test func bothKeysHaveSettingsRows() {
        let paths = Set(SettingsSchema.all.map { $0.path.joined(separator: ".") })
        #expect(paths.contains("browser.agentMouse.motion"))
        #expect(paths.contains("browser.agentMouse.maxMoveMs"))
    }
}
