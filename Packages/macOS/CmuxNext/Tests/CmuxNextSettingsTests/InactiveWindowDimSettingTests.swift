import CmuxNextSettings
import Testing

/// `appearance.inactiveWindowDim`: 0 unless set, so a window looks the same in front and behind
/// (Leo, 2026-10-20); a value from 0 to 1 dims windows that are not key.
struct InactiveWindowDimSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["inactiveWindowDim": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.inactiveWindowDim == 0)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(SettingsSchema.descriptor(for: WindowBackgroundSetting.inactiveDimPath) != nil)
    }

    @Test func aValueInRangeApplies() {
        #expect(Self.parse(.number(0.15)).inactiveWindowDim == 0.15)
        #expect(Self.parse(.number(1)).inactiveWindowDim == 1)
    }

    @Test func aBadValueKeepsZeroAndSaysSo() {
        for bad: JSONValue in [.number(1.5), .number(-0.1), .string("dim")] {
            let snapshot = Self.parse(bad)
            #expect(snapshot.inactiveWindowDim == 0)
            #expect(snapshot.diagnostics.contains { $0.path == "appearance.inactiveWindowDim" })
        }
    }
}
