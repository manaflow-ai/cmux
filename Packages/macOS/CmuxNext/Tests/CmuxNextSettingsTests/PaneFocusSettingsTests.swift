import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.focusIndicator` and `appearance.tabBarBackground`.
@Suite struct PaneFocusSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.focusIndicator == .both)
        #expect(snapshot.tabBarBackground == .window)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsBoth() throws {
        let snapshot = try parse(#"{"appearance": {"focusIndicator": "tabs", "tabBarBackground": "darker"}}"#)
        #expect(snapshot.focusIndicator == .tabs)
        #expect(snapshot.tabBarBackground == .darker)
    }

    @Test func badValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"appearance": {"focusIndicator": "glow", "tabBarBackground": 3}}"#)
        #expect(snapshot.focusIndicator == .both)
        #expect(snapshot.tabBarBackground == .window)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["appearance.focusIndicator", "appearance.tabBarBackground"])
    }

    @MainActor @Test func appliesAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"appearance": {"focusIndicator": "none", "tabBarBackground": "darker"}}"#))
        #expect(design.focusIndicator == .none)
        #expect(design.tabBarBackground == .darker)
        applier.apply(try parse("{}"))
        #expect(design.focusIndicator == .both)
        #expect(design.tabBarBackground == .window)
    }

    @Test func theSettingsWindowOffersThem() {
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "focusIndicator"] })
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "tabBarBackground"] })
    }
}
