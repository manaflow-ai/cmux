import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.background` defaults to a figure drawing (cx-t2x); `none` turns it off and
/// `desktop` picks the desktop picture, which is never the default.
struct BackgroundDefaultSettingsTests {
    static let defaultID = "nga-degas-halevy-standing-66489"

    @Test func unsetIsTheDefaultFigureDrawing() throws {
        #expect(try parse("{}").backdropSelection?.id == Self.defaultID)
        #expect(try parse("{}").backdropArt?.rawValue == Self.defaultID)
        #expect(CmuxConfigSnapshot.empty.backdropSelection?.id == Self.defaultID)
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath))
        #expect(descriptor.defaultValue == .string(Self.defaultID))
    }

    @Test func noneTurnsItOff() throws {
        let snapshot = try parse(#"{"appearance":{"background":"none"}}"#)
        #expect(snapshot.backdropSelection == nil)
        #expect(snapshot.backdropArt == nil)
        // The legacy key still turns it off when the new one is unset.
        #expect(try parse(#"{"appearance":{"backdropArt":"none"}}"#).backdropSelection == nil)
    }

    @Test func desktopIsAnOptInChoice() throws {
        let snapshot = try parse(#"{"appearance":{"background":"desktop"}}"#)
        #expect(snapshot.backdropSelection?.id == "desktop")
        #expect(snapshot.backdropArt == nil)
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath))
        #expect(descriptor.accepts("desktop"))
        #expect(descriptor.accepts(.string(Self.defaultID)))
    }

    @Test func anInvalidValueFallsBackToTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"appearance":{"background":"__not_a_backdrop__"}}"#)
        #expect(snapshot.backdropSelection?.id == Self.defaultID)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.background" && $0.kind == .invalidValue })
    }

    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }
}
