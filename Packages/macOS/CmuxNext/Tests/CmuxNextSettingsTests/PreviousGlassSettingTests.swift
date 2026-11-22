import CmuxNextSettings
import Testing

/// `appearance.previousGlass`: off by default, so web pages draw the one glass system
/// (design/glass-system.md); on brings back the glass numbers from before it, one toggle in Appearance.
struct PreviousGlassSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["previousGlass": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.previousGlass == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).previousGlass)
        #expect(Self.parse(.bool(false)).previousGlass == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.previousGlass == false)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.previousGlass" }, "\(snapshot.diagnostics)")
    }

    @Test func itIsOneToggleInAppearance() throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.path == PreviousGlassSetting.configPath })
        #expect(descriptor.section == .appearance)
        #expect(descriptor.kind == .toggle)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
    }
}
