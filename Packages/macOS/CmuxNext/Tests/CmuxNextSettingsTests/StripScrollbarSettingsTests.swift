import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.stripScrollbar`: "system" (follow the macOS "Show scroll bars" setting) unless the file
/// says "auto", "always" or "off" (booleans too); a bad value keeps "system" with a diagnostic.
@Suite struct StripScrollbarSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToFollowingTheSystem() throws {
        #expect(try parse("{}").stripScrollbar == .system)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryModeAndBooleans() throws {
        #expect(try parse(#"{"layout": {"stripScrollbar": "always"}}"#).stripScrollbar == .always)
        #expect(try parse(#"{"layout": {"stripScrollbar": "off"}}"#).stripScrollbar == .off)
        #expect(try parse(#"{"layout": {"stripScrollbar": "auto"}}"#).stripScrollbar == .auto)
        #expect(try parse(#"{"layout": {"stripScrollbar": "system"}}"#).stripScrollbar == .system)
        #expect(try parse(#"{"layout": {"stripScrollbar": false}}"#).stripScrollbar == .off)
        #expect(try parse(#"{"layout": {"stripScrollbar": true}}"#).stripScrollbar == .auto)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"layout": {"stripScrollbar": "sometimes"}}"#)
        #expect(snapshot.stripScrollbar == .system)
        #expect(snapshot.diagnostics.map(\.path) == ["layout.stripScrollbar"])
    }

    @Test func thePaletteToggleFlipsOffAndOn() {
        #expect(StripScrollbarMode.off.toggled == .system)
        #expect(StripScrollbarMode.system.toggled == .off)
        #expect(StripScrollbarMode.auto.toggled == .off)
        #expect(StripScrollbarMode.always.toggled == .off)
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"stripScrollbar": "off"}}"#))
        #expect(design.stripScrollbar == .off)
        applier.apply(try parse("{}"))
        #expect(design.stripScrollbar == .system)
    }

    /// "system" is "auto" (shown while scrolling) for overlay scrollers and "always" for legacy
    /// ones ("Always", or "Automatically" with a mouse); an explicit choice stays as chosen.
    @Test func systemFollowsTheMacOSScrollerStyle() {
        #expect(StripScrollbarMode.system.resolved(legacyScrollers: false) == .auto)
        #expect(StripScrollbarMode.system.resolved(legacyScrollers: true) == .always)
        for mode in [StripScrollbarMode.auto, .always, .off] {
            #expect(mode.resolved(legacyScrollers: false) == mode)
            #expect(mode.resolved(legacyScrollers: true) == mode)
        }
    }
}
