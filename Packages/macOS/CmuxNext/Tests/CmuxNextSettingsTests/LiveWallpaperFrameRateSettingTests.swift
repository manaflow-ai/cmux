import CmuxNextSettings
import Testing

/// `appearance.liveWallpaperFrameRate`: the most frames per second a live wallpaper draws, "15",
/// "30" (the default) or "60"; anything else is the default with a diagnostic. And `live:<id>` is
/// a background `appearance.background` accepts.
struct LiveWallpaperFrameRateSettingTests {
    private static func snapshot(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func thirtyWhenUnset() {
        let parsed = Self.snapshot([:])
        #expect(parsed.liveWallpaperFrameRate == 30)
        #expect(!parsed.diagnostics.contains { $0.path == "appearance.liveWallpaperFrameRate" })
    }

    @Test(arguments: [("15", 15), ("30", 30), ("60", 60)])
    func eachChoiceIsItsRate(value: String, fps: Int) {
        #expect(Self.snapshot(["liveWallpaperFrameRate": .string(value)]).liveWallpaperFrameRate == fps)
    }

    @Test(arguments: [JSONValue.string("120"), .string("fast"), .number(60), .bool(true)])
    func anythingElseIsThirtyWithADiagnostic(value: JSONValue) {
        let parsed = Self.snapshot(["liveWallpaperFrameRate": value])
        #expect(parsed.liveWallpaperFrameRate == 30)
        #expect(parsed.diagnostics.contains { $0.path == "appearance.liveWallpaperFrameRate" })
    }

    @Test func aLiveBackgroundParsesWithoutADiagnostic() {
        let parsed = Self.snapshot(["background": .string("live:ink-drift")])
        #expect(parsed.backdropSelection?.id == "live:ink-drift")
        #expect(!parsed.diagnostics.contains { $0.path == "appearance.background" })
    }
}
