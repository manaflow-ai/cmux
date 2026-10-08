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

    /// `computerUse.driver` defaults to legacy: an existing cmux.json keeps
    /// today's helper path.
    @Test func theDriverIsLegacyByDefault() throws {
        #expect(ComputerUseSettings().driver == .legacy)
        #expect(try parse("{}").computerUse.driver == .legacy)
        #expect(try parse(#"{"computerUse": {"enabled": true}}"#).computerUse.driver == .legacy)
        let row = try #require(SettingsSchema.descriptor(for: ComputerUseSettings.driverPath))
        #expect(row.defaultValue == .string("legacy"))
    }

    @Test func theDriverReadsUpstreamAndRejectsUnknownValues() throws {
        let upstream = try parse(#"{"computerUse": {"enabled": true, "driver": "upstream"}}"#)
        #expect(upstream.computerUse.driver == .upstream)
        #expect(upstream.diagnostics.isEmpty)
        let bad = try parse(#"{"computerUse": {"driver": "fork"}}"#)
        #expect(bad.computerUse.driver == .legacy)
        #expect(bad.diagnostics.contains { $0.path == "computerUse.driver" })
    }

    @Test func anAgentMayNotChangeTheDriver() {
        #expect(!SettingsSchema.agentSettableKeys.contains("computerUse.driver"))
        #expect(SettingsSchema.agentRefusedKeys["computerUse.driver"] == .userOnly)
    }
}
