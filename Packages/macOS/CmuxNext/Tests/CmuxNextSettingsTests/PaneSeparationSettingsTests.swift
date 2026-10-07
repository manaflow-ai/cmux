import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `layout.paneSeparation` in cmux.json and the settings schema (R93).
@Suite struct PaneSeparationSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test(arguments: PaneSeparation.allCases)
    func parsesEveryChoice(_ separation: PaneSeparation) throws {
        let snapshot = try parse(#"{"layout": {"paneSeparation": "\#(separation.rawValue)"}}"#)
        #expect(snapshot.paneChrome.separation == separation)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func unsetFollowsTheLegacyKeys() throws {
        #expect(try parse("{}").paneChrome.separation == nil)
    }

    @Test func aBadValueIsSkippedWithADiagnostic() throws {
        let snapshot = try parse(#"{"layout": {"paneSeparation": "lines"}}"#)
        #expect(snapshot.paneChrome.separation == nil)
        #expect(snapshot.diagnostics.map(\.path) == ["layout.paneSeparation"])
    }

    /// The schema row the Settings page, the palette and the CLI read.
    @Test func theSchemaOffersEveryChoiceWithBordersAsTheDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["layout", "paneSeparation"]))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice, got \(descriptor.kind)")
            return
        }
        #expect(choices.map(\.value) == ["none", "dividers", "borders", "cards"])
        #expect(descriptor.defaultValue == .string("borders"))
        #expect(descriptor.section == .appearance)
    }
}
