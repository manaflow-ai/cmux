import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium's wake-up alignment (p14-energy-040). `AlignWakeUps` snaps each delayed wake of every
/// Chromium thread to one 8 ms grid, and `BatterySaverModeAlignWakeUps` lets battery saver widen
/// it to 32 ms in child processes. Both are `FEATURE_DISABLED_BY_DEFAULT` and Chrome turns them on
/// only through field trials, which `disable-field-trial-config` leaves off, so cmux names them.
/// `TimerSlackMac` waits for the fork API with the absolute delayed run time (p14-energy-046).
@Suite struct CEFSwitchesTests {
    static let forkAPIs: [Int32] = [0, 7, 26, CEFSwitches.resizeSyncForkAPI, CEFForkFeatures.rendererPathsForkAPI]

    static func switches(forkAPIVersion: Int32, bundle: String = "com.cmuxterm.app.next",
                         keepsUnpackedEnabled: Bool = true) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion,
                            rendererPaths: forkAPIVersion >= CEFForkFeatures.rendererPathsForkAPI,
                            bundleIdentifier: bundle, environment: [:],
                            keepsUnpackedEnabled: keepsUnpackedEnabled).arguments
    }

    static func enabledFeatures(_ switches: [String]) -> [String] {
        switches
            .filter { $0.hasPrefix("enable-features=") }
            .flatMap { $0.dropFirst("enable-features=".count).split(separator: ",").map(String.init) }
    }

    @Test(arguments: forkAPIs)
    func chromiumAlignsItsWakeUps(forkAPIVersion: Int32) {
        let features = Self.enabledFeatures(Self.switches(forkAPIVersion: forkAPIVersion))
        #expect(features.contains("AlignWakeUps"))
        #expect(features.contains("BatterySaverModeAlignWakeUps"))
    }

    @Test(arguments: forkAPIs, ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func everyEnabledFeatureIsInOneEntry(forkAPIVersion: Int32, bundle: String) {
        let switches = Self.switches(forkAPIVersion: forkAPIVersion, bundle: bundle)
        #expect(switches.filter { $0.hasPrefix("enable-features=") }.count == 1)
        let features = Self.enabledFeatures(switches)
        #expect(features.contains(CEFSwitches.chromePromptOffFeature))
        #expect(Set(features).count == features.count)
    }

    /// Every fork API the app knows today is older than p14-energy-046's; that task moves this
    /// bound to its own API and asserts `TimerSlackMac` from there on.
    @Test func noForkAPIBeforeTheAbsoluteRunTimeTurnsOnTimerSlack() {
        for forkAPIVersion in Int32(0)...CEFForkFeatures.rendererPathsForkAPI {
            #expect(!Self.enabledFeatures(Self.switches(forkAPIVersion: forkAPIVersion)).contains("TimerSlackMac"),
                    "fork API \(forkAPIVersion)")
        }
    }

    @Test func theChromiumHostAlignsItsWakeUpsToo() {
        let root = URL(filePath: "/tmp/cmux-cef-switches-test", directoryHint: .isDirectory)
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let hostSwitches = ChromiumHostConfiguration.arguments(
            layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
            .filter { $0.hasPrefix("--cef-switch=") }
            .map { String($0.dropFirst("--cef-switch=".count)) }
        #expect(hostSwitches.filter { $0.hasPrefix("enable-features=") }.count == 1)
        #expect(Set(CEFSwitches.wakeUpAlignmentFeatures).isSubset(of: Self.enabledFeatures(hostSwitches)))
    }
}
