import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.background` stays off until the user picks art (cx-t2x: opt-in, never forced on).
/// A figure drawing or `desktop` turns it on; `none` and an unset key leave it off.
struct BackgroundDefaultSettingsTests {
    static let drawingID = "nga-degas-halevy-standing-66489"

    @Test func unsetLeavesTheBackgroundOff() throws {
        #expect(try parse("{}").backdropSelection == nil)
        #expect(try parse("{}").backdropArt == nil)
        #expect(CmuxConfigSnapshot.empty.backdropSelection == nil)
        #expect(CmuxConfigSnapshot.empty.backdropArt == nil)
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath))
        #expect(descriptor.defaultValue == .string("none"))
    }

    @Test func aDrawingTurnsItOnAndNoneTurnsItOff() throws {
        let drawing = try parse(#"{"appearance":{"background":"nga-degas-halevy-standing-66489"}}"#)
        #expect(drawing.backdropSelection?.id == Self.drawingID)
        #expect(drawing.backdropArt?.rawValue == Self.drawingID)
        let off = try parse(#"{"appearance":{"background":"none"}}"#)
        #expect(off.backdropSelection == nil)
        #expect(off.backdropArt == nil)
        #expect(try parse(#"{"appearance":{"backdropArt":"none"}}"#).backdropSelection == nil)
    }

    @Test func desktopIsAnOptInChoice() throws {
        let snapshot = try parse(#"{"appearance":{"background":"desktop"}}"#)
        #expect(snapshot.backdropSelection?.id == "desktop")
        #expect(snapshot.backdropArt == nil)
        let descriptor = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting().configPath))
        #expect(descriptor.accepts("desktop"))
        #expect(descriptor.accepts(.string(Self.drawingID)))
    }

    @Test func anInvalidValueLeavesItOffWithADiagnostic() throws {
        let snapshot = try parse(#"{"appearance":{"background":"__not_a_backdrop__"}}"#)
        #expect(snapshot.backdropSelection == nil)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.background" && $0.kind == .invalidValue })
    }

    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }
}
