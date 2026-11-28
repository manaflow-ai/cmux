import Foundation
import Testing
@testable import CmuxNextBrowser

/// Idle wakeups (cmux20-bench, 2026-11-27: the app at 3.24/s against a 1.0/s budget, with no page
/// reloading). The browser process is the app, and Chromium's UI thread is its main thread, so
/// each delayed task Chromium posts there is a wake of the app's message pump. Two fixed-period
/// timers ran at idle (Chromium 151):
/// - `SystemMemoryPressureEvaluator::CheckDiskSpace` every 5 s (MacCriticalDiskSpacePressure): a
///   main-thread timer, a thread-pool disk read and a reply back on the main thread. macOS's own
///   memory pressure signal stays on.
/// - The PartitionAlloc memory reclaimer every 4 s, in the app and in every renderer. It returns
///   memory freed since its last pass; an idle app frees almost none, so it runs every 30 s.
@Suite struct CEFIdleTimerSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func chromiumsDiskSpacePollIsOff(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("disable-features=MacCriticalDiskSpacePressure"))
    }

    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func theMemoryReclaimerRunsEveryThirtySeconds(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("enable-features=PartitionAllocMemoryReclaimer:interval/30s"))
    }
}
