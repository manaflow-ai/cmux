import CmuxNextSettings
import Testing

/// `appearance.videoWallpaperIdlePause`: a video background (a local movie or YouTube) pauses after
/// this many seconds with no keyboard or mouse input and resumes on the next input; 300 unless set,
/// 0 never pauses.
struct VideoWallpaperIdlePauseSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["videoWallpaperIdlePause": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func fiveMinutesByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.videoWallpaperIdlePause == 300)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(SettingsSchema.descriptor(for: WindowBackgroundSetting.videoWallpaperIdlePausePath) != nil)
    }

    @Test func aValueInRangeApplies() {
        #expect(Self.parse(.number(60)).videoWallpaperIdlePause == 60)
        #expect(Self.parse(.number(86_400)).videoWallpaperIdlePause == 86_400)
    }

    @Test func zeroNeverPauses() {
        let snapshot = Self.parse(.number(0))
        #expect(snapshot.videoWallpaperIdlePause == 0)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysSo() {
        for bad: JSONValue in [.number(-1), .number(86_401), .number(2.5), .string("5m"), .bool(true)] {
            let snapshot = Self.parse(bad)
            #expect(snapshot.videoWallpaperIdlePause == 300)
            #expect(snapshot.diagnostics.contains { $0.path == "appearance.videoWallpaperIdlePause" })
        }
    }
}
