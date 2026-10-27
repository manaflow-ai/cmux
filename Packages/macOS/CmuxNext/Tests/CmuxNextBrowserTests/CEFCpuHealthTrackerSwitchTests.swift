import Foundation
import Testing
@testable import CmuxNextBrowser

/// p14-energy-043 (Q8): Chromium's `CpuHealthTracker` sampled system CPU every 15 s from a timer on the
/// browser UI thread, which is the app's main thread, for the performance intervention button in a
/// toolbar Chromium never shows in cmux. The fork patch `cmux_cpu_health_tracker_hidden_ui`
/// (manaflow-ai/cef `cp/p14-energy-043`) turns the probe off when the browser process has
/// `cmux-tabbed-windows`, so that switch must reach the browser process on every fork, spelled the way
/// the fork reads it (libcef/common/cef_switches.cc `kCmuxTabbedWindows`).
@Suite struct CEFCpuHealthTrackerSwitchTests {
    private func switches(forkAPIVersion: Int32) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
            .arguments
    }

    @Test(arguments: [Int32(1), 27, 33])
    func everyForkGetsTheSwitchThatStopsTheSampling(forkAPIVersion: Int32) {
        let arguments = switches(forkAPIVersion: forkAPIVersion)
        #expect(arguments.filter { $0 == "cmux-tabbed-windows" }.count == 1, "\(arguments)")
    }

    @Test func stockCEFHasNoForkSwitch() {
        #expect(!switches(forkAPIVersion: 0).contains("cmux-tabbed-windows"))
    }
}
