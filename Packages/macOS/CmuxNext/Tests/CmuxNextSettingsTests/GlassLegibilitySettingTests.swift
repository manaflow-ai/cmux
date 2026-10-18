import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `appearance.glassLegibility`: "primary" (Main Text, like iOS) unless the file says "all".
struct GlassLegibilitySettingTests {
    @Test func mainTextByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.glassLegibility == .primary)
        #expect(SettingsSchema.descriptor(for: GlassLegibilitySetting.configPath) != nil)
    }

    @Test func allTextFromTheFileAndABadValueFallsBack() {
        let all = JSONValue.object(["appearance": .object(["glassLegibility": .string("all")])])
        #expect(CmuxConfigSnapshot.parse(all, validDensities: [], validMetrics: []).glassLegibility == .all)
        let bad = JSONValue.object(["appearance": .object(["glassLegibility": .string("ios")])])
        let snapshot = CmuxConfigSnapshot.parse(bad, validDensities: [], validMetrics: [])
        #expect(snapshot.glassLegibility == .primary)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.glassLegibility" })
    }
}
