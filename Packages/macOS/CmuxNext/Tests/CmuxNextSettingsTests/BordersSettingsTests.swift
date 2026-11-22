import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `appearance.borders`: "default" unless the file says "none"; a bad value
/// keeps "default" with a diagnostic; removing the key restores it.
@Suite struct BordersSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToDefault() throws {
        #expect(try parse("{}").borders == .default)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsNone() throws {
        #expect(try parse(#"{"appearance": {"borders": "none"}}"#).borders == .none)
    }

    @Test func badValuesKeepDefaultWithADiagnostic() throws {
        for text in [#"{"appearance": {"borders": "thin"}}"#, #"{"appearance": {"borders": false}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.borders == .default, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["appearance.borders"], "\(text)")
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"appearance": {"borders": "none"}}"#))
        #expect(design.borders == .none)
        applier.apply(try parse("{}"))
        #expect(design.borders == .default)
    }

    @Test func theSettingsWindowOffersIt() {
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "borders"] })
    }
}
