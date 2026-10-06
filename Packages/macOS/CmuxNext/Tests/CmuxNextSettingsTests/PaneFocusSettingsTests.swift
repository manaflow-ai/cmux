import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.focusIndicator` and `focus.inactiveTabStyle`
/// (`appearance.tabBarBackground` is gone: one background everywhere).
@Suite struct PaneFocusSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.focusIndicator == .both)
        #expect(snapshot.inactiveTabStyle == .fade)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsInactiveTabStyle() throws {
        #expect(try parse(#"{"focus": {"inactiveTabStyle": "tonal"}}"#).inactiveTabStyle == .tonal)
        #expect(try parse(#"{"focus": {"inactiveTabStyle": "quiet"}}"#).inactiveTabStyle == .quiet)
    }

    @Test func badInactiveTabStyleKeepsFadeWithDiagnostic() throws {
        let snapshot = try parse(#"{"focus": {"inactiveTabStyle": "dim"}}"#)
        #expect(snapshot.inactiveTabStyle == .fade)
        #expect(snapshot.diagnostics.map(\.path) == ["focus.inactiveTabStyle"])
    }

    @Test func readsBoth() throws {
        let snapshot = try parse(#"{"appearance": {"focusIndicator": "tabs"}}"#)
        #expect(snapshot.focusIndicator == .tabs)
    }

    @Test func badValuesKeepDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"appearance": {"focusIndicator": "glow"}}"#)
        #expect(snapshot.focusIndicator == .both)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["appearance.focusIndicator"])
    }

    @MainActor @Test func appliesAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"appearance": {"focusIndicator": "none"}, "focus": {"inactiveTabStyle": "quiet"}}"#))
        #expect(design.focusIndicator == .none)
        #expect(design.inactiveTabStyle == .quiet)
        #expect(design.effectiveInactiveTabStyle == .quiet)
        applier.apply(try parse("{}"))
        #expect(design.focusIndicator == .both)
        #expect(design.inactiveTabStyle == .fade)
    }

    @Test func theSettingsWindowOffersThem() {
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "focusIndicator"] })
        #expect(!SettingsSchema.all.contains { $0.path == ["appearance", "tabBarBackground"] }, "one background everywhere")
        #expect(SettingsSchema.all.contains { $0.path == ["focus", "inactiveTabStyle"] })
    }
}
