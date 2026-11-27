import CmuxNextSettings
import Testing

/// `appearance.wallpaperLighting`: off unless set to true, with a Settings toggle to turn it on.
struct WallpaperLightingSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["wallpaperLighting": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func offByDefaultWithAToggle() {
        let snapshot = Self.parse(nil)
        #expect(!snapshot.wallpaperLighting)
        #expect(snapshot.diagnostics.isEmpty)
        let descriptor = SettingsSchema.descriptor(for: WallpaperLightingSetting.configPath)
        #expect(descriptor?.defaultValue == .bool(false))
    }

    @Test func trueTurnsItOn() {
        #expect(Self.parse(.bool(true)).wallpaperLighting)
        #expect(!Self.parse(.bool(false)).wallpaperLighting)
    }

    @Test func aBadValueKeepsItOffAndSaysSo() {
        let snapshot = Self.parse(.string("on"))
        #expect(!snapshot.wallpaperLighting)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.wallpaperLighting" })
    }
}
