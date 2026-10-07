import CmuxNextSettings
import Foundation
import Testing

/// `computerUse.enabled` (off by default) is what lets cmux start the
/// signed Computer Use helper. Only the person turns it on: an agent may
/// not set it.
@Suite struct ComputerUseSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func itIsOffByDefaultAndReadFromTheFile() throws {
        #expect(try parse("{}").computerUse.enabled == false)
        let on = try parse(#"{"computerUse": {"enabled": true}}"#)
        #expect(on.computerUse.enabled)
        #expect(on.diagnostics.isEmpty)
        let row = try #require(SettingsSchema.descriptor(for: ComputerUseSettings.enabledPath))
        #expect(row.defaultValue == .bool(false))
    }

    @Test func anAgentMayNotTurnItOn() {
        #expect(!SettingsSchema.agentSettableKeys.contains("computerUse.enabled"))
        #expect(SettingsSchema.agentRefusedKeys["computerUse.enabled"] == .userOnly)
    }
}
