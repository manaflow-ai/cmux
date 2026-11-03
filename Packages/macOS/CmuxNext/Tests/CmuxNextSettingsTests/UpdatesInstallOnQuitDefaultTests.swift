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

    /// Automatic checks stay on. `downloadAutomatically` is not asserted here: its default is per
    /// channel (stable off, the nightly and dev apps seed it on; cbb4aa7ba1a).
    @Test func checksStayOnWhenUnset() {
        #expect(Self.parse([:]).updates.checkAutomatically)
    }

    /// An explicit `true` in cmux.json is the person's own choice and still wins.
    @Test func anExplicitTrueStillInstallsOnQuit() {
        #expect(Self.parse(["installOnQuit": .bool(true)]).updates.installOnQuit)
    }
}
