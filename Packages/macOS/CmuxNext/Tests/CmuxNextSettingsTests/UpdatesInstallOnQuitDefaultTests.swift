import CmuxNextSettings
import Testing

/// `updates.installOnQuit` defaults off (nightly restart policy, 2026-10-27): automatic checks and
/// downloads stay on, but a downloaded update installs and relaunches only on the person's click.
struct UpdatesInstallOnQuitDefaultTests {
    private static func parse(_ updates: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["updates": .object(updates)]), validDensities: [], validMetrics: [])
    }

    @Test func installOnQuitIsOffWhenUnset() {
        #expect(Self.parse([:]).updates.installOnQuit == false)
        #expect(UpdatesSettings.installOnQuitDefault == false)
    }

    @Test func checksAndDownloadsStayOnWhenUnset() {
        let snapshot = Self.parse([:])
        #expect(snapshot.updates.checkAutomatically)
        #expect(snapshot.updates.downloadAutomatically)
    }

    /// An explicit `true` in cmux.json is the person's own choice and still wins.
    @Test func anExplicitTrueStillInstallsOnQuit() {
        #expect(Self.parse(["installOnQuit": .bool(true)]).updates.installOnQuit)
    }
}
