import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `window.titlebarButtons` (R83): hover (default) or always.
@Suite struct TitlebarButtonsSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func defaultsToHover() throws {
        #expect(try parse("{}").titlebarButtons == .hover)
    }

    @Test func parsesAlwaysAndRefusesOtherText() throws {
        #expect(try parse(#"{"window": {"titlebarButtons": "always"}}"#).titlebarButtons == .always)
        let bad = try parse(#"{"window": {"titlebarButtons": "never"}}"#)
        #expect(bad.titlebarButtons == .hover)
        #expect(bad.diagnostics.map(\.path) == ["window.titlebarButtons"])
    }

    @Test func isASchemaChoice() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["window", "titlebarButtons"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(choices.map(\.value) == ["hover", "always"])
        #expect(descriptor.defaultValue == "hover")
    }
}
