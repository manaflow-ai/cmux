import Foundation
import Testing
@testable import CmuxNextBrowser

/// Idle wakeups (cmux20-bench, 2026-11-27: the app at 3.24/s against a 1.0/s budget, with no page
/// reloading). The browser process is the app, and Chromium's UI thread is its main thread, so
/// each delayed task Chromium posts there is a wake of the app's message pump.
/// - The PartitionAlloc memory reclaimer ran every 4 s, in the app and in every renderer. It returns
///   memory freed since its last pass; an idle app frees almost none, so it runs every 30 s.
/// - No switch names a feature the pinned Chromium does not read. `MacCriticalDiskSpacePressure`
///   gated `SystemMemoryPressureEvaluator::CheckDiskSpace` (every 5 s) in Chromium 151; Chromium
///   154 starts that timer with no feature check, and a 154 trace with the switch on still ran it
///   12 times a minute (cmux20-bench, 2026-11-28). Only a fork change turns that poll off.
@Suite struct CEFIdleTimerSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func noSwitchNamesTheDiskSpaceFeatureChromium154Dropped(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(!switches.arguments.contains { $0.contains("MacCriticalDiskSpacePressure") })
    }

    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func theMemoryReclaimerRunsEveryThirtySeconds(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("enable-features=PartitionAllocMemoryReclaimer:interval/30s"))
    }
}
