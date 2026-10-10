import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.stripScrollbar`: "auto" unless the file says "always" or "off"
/// (booleans too); a bad value keeps "auto" with a diagnostic.
@Suite struct StripScrollbarSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToAuto() throws {
        #expect(try parse("{}").stripScrollbar == .auto)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryModeAndBooleans() throws {
        #expect(try parse(#"{"layout": {"stripScrollbar": "always"}}"#).stripScrollbar == .always)
        #expect(try parse(#"{"layout": {"stripScrollbar": "off"}}"#).stripScrollbar == .off)
        #expect(try parse(#"{"layout": {"stripScrollbar": "auto"}}"#).stripScrollbar == .auto)
        #expect(try parse(#"{"layout": {"stripScrollbar": false}}"#).stripScrollbar == .off)
        #expect(try parse(#"{"layout": {"stripScrollbar": true}}"#).stripScrollbar == .auto)
    }

    @Test func badValuesKeepAutoWithADiagnostic() throws {
        let snapshot = try parse(#"{"layout": {"stripScrollbar": "sometimes"}}"#)
        #expect(snapshot.stripScrollbar == .auto)
        #expect(snapshot.diagnostics.map(\.path) == ["layout.stripScrollbar"])
    }

    @Test func thePaletteToggleFlipsOffAndOn() {
        #expect(StripScrollbarMode.off.toggled == .auto)
        #expect(StripScrollbarMode.auto.toggled == .off)
        #expect(StripScrollbarMode.always.toggled == .off)
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"stripScrollbar": "off"}}"#))
        #expect(design.stripScrollbar == .off)
        applier.apply(try parse("{}"))
        #expect(design.stripScrollbar == .auto)
    }
}
