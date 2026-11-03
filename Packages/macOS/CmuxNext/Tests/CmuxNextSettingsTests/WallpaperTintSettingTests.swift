import CmuxNextSettings
import Testing

/// `appearance.wallpaperTint`: on unless set to false, so the glass follows the desktop picture
/// out of the box (Leo, 2026-10-20), with a Settings toggle to turn it off.
struct WallpaperTintSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["wallpaperTint": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func onByDefaultWithAToggle() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.wallpaperTint)
        #expect(snapshot.diagnostics.isEmpty)
        let descriptor = SettingsSchema.descriptor(for: WallpaperTintSetting().configPath)
        #expect(descriptor?.defaultValue == .bool(true))
    }

    @Test func falseTurnsItOff() {
        #expect(!Self.parse(.bool(false)).wallpaperTint)
        #expect(Self.parse(.bool(true)).wallpaperTint)
    }

    @Test func aBadValueKeepsItOnAndSaysSo() {
        let snapshot = Self.parse(.string("off"))
        #expect(snapshot.wallpaperTint)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.wallpaperTint" })
    }
}
