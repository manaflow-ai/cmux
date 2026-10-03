import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.focusIndicator`, `appearance.tabBarBackground` and
/// `focus.inactiveTabStyle`.
@Suite struct PaneFocusSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.focusIndicator == .both)
        #expect(snapshot.tabBarBackground == .window)
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
        applier.apply(try parse(#"{"appearance": {"focusIndicator": "none", "tabBarBackground": "darker"}, "focus": {"inactiveTabStyle": "quiet"}}"#))
        #expect(design.focusIndicator == .none)
        #expect(design.tabBarBackground == .darker)
        #expect(design.inactiveTabStyle == .quiet)
        #expect(design.effectiveInactiveTabStyle == .quiet)
        applier.apply(try parse("{}"))
        #expect(design.focusIndicator == .both)
        #expect(design.tabBarBackground == .window)
        #expect(design.inactiveTabStyle == .fade)
    }

    @Test func theSettingsWindowOffersThem() {
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "focusIndicator"] })
        #expect(SettingsSchema.all.contains { $0.path == ["appearance", "tabBarBackground"] })
        #expect(SettingsSchema.all.contains { $0.path == ["focus", "inactiveTabStyle"] })
    }
}
