import CmuxNextSettings
import Testing

/// `appearance.liveWallpaperGrade`: the tritone grade over a live wallpaper, a number from 0 (the
/// default: off) to 1; anything else is the default with a diagnostic.
struct LiveWallpaperGradeSettingTests {
    private static func snapshot(_ appearance: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func offWhenUnset() {
        let parsed = Self.snapshot([:])
        #expect(parsed.liveWallpaperGrade == 0)
        #expect(!parsed.diagnostics.contains { $0.path == "appearance.liveWallpaperGrade" })
    }

    @Test(arguments: [0.0, 0.35, 1.0])
    func aNumberInRangeIsTheAmount(amount: Double) {
        #expect(Self.snapshot(["liveWallpaperGrade": .number(amount)]).liveWallpaperGrade == amount)
    }

    @Test(arguments: [JSONValue.number(1.5), .number(-0.1), .string("0.5"), .bool(true)])
    func anythingElseIsOffWithADiagnostic(value: JSONValue) {
        let parsed = Self.snapshot(["liveWallpaperGrade": value])
        #expect(parsed.liveWallpaperGrade == 0)
        #expect(parsed.diagnostics.contains { $0.path == "appearance.liveWallpaperGrade" })
    }
}
