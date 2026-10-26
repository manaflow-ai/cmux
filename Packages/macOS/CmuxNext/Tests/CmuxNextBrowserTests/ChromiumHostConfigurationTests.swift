@testable import CmuxNextBrowser
import Testing

/// The Chromium host's switches: the app's set (the same wake alignment and
/// idle disables), Chromium's own timer slack, one entry per feature list.
@Suite struct ChromiumHostConfigurationTests {
    private static func switches() -> [String] {
        ChromiumHostConfiguration.switches(bundleIdentifier: "com.cmuxterm.app", environment: [:])
    }

    private static func entries(_ name: String, in switches: [String]) -> [String] {
        switches.filter { $0.hasPrefix(name + "=") }
    }

    @Test func theHostHasEveryAppSwitchButThePumpSlice() {
        let app = CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI, bundleIdentifier: "com.cmuxterm.app",
                                      environment: [:]).arguments
        let host = Self.switches()
        for entry in app where !entry.hasPrefix("cmux-pump-time-slice-us=") && !entry.hasPrefix("enable-features=")
            && !entry.hasPrefix("disable-features=") {
            #expect(host.contains(entry), "missing \(entry)")
        }
        #expect(!host.contains { $0.hasPrefix("cmux-pump-time-slice-us=") })
        // Every feature the app enables, the host enables too.
        let hostEnabled = Set(Self.features("enable-features", in: host))
        for feature in Self.features("enable-features", in: app) {
            #expect(hostEnabled.contains(feature), "missing feature \(feature)")
        }
    }

    private static func features(_ name: String, in switches: [String]) -> [String] {
        entries(name, in: switches).flatMap { $0.dropFirst(name.count + 1).split(separator: ",").map(String.init) }
    }

    @Test func timerSlackAndTheCodeSignCloneAreInOneEntryEach() {
        let host = Self.switches()
        let enabled = Self.entries("enable-features", in: host)
        let disabled = Self.entries("disable-features", in: host)
        #expect(enabled.count == 1)
        #expect(disabled == ["disable-features=MacAppCodeSignClone"])
        #expect(enabled.first?.split(separator: ",").contains { $0.hasSuffix("TimerSlackMac") } == true)
        #expect(enabled.first?.contains("IPH_DemoMode:chosen_feature/IPH_Dummy") == true)
    }

    @Test func mergingKeepsOrderPlaceAndEachFeatureOnce() {
        let merged = ChromiumHostConfiguration.mergingFeatureList(
            "enable-features", adding: ["C", "A"],
            into: ["x", "enable-features=A,B", "y", "enable-features= B ,D", "disable-features=E"])
        #expect(merged == ["x", "enable-features=A,B,D,C", "y", "disable-features=E"])
        #expect(ChromiumHostConfiguration.mergingFeatureList("disable-features", adding: ["F"], into: ["x"])
            == ["x", "disable-features=F"])
        #expect(ChromiumHostConfiguration.mergingFeatureList("disable-features", adding: [], into: ["x", "disable-features="])
            == ["x"])
    }
}
