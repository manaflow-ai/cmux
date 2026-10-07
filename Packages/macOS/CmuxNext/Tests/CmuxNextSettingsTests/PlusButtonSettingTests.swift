import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `tabs.plusButton` (R120): hover (default) or always.
@Suite struct PlusButtonSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func defaultsToHoverAndParsesAlways() throws {
        #expect(try parse("{}").plusButton == .hover)
        #expect(try parse(#"{"tabs": {"plusButton": "always"}}"#).plusButton == .always)
        let bad = try parse(#"{"tabs": {"plusButton": 1}}"#)
        #expect(bad.plusButton == .hover)
        #expect(bad.diagnostics.map(\.path) == ["tabs.plusButton"])
    }

    @Test func isASchemaChoiceForSettingsAndThePalette() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "plusButton"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(choices.map(\.value) == ["hover", "always"])
        #expect(descriptor.defaultValue == "hover")
        #expect(descriptor.isPaletteExposed)
    }
}
