import Foundation
import Testing
@testable import CmuxNextBrowser

/// Idle power (msg 2654): with 20 hidden tabs the app's own energy rose from about 0.24 mW to
/// 2.6 to 4.3 mW in some runs on cmux14. Stack samples taken inside those windows showed
/// Chromium's StackSamplingProfiler thread, which is absent in the normal ones: Chromium's
/// periodic call-stack profiler runs in the browser process, which is the app. Its profiles go to
/// UMA, which cmux does not upload, so the browser process starts with `disable-stack-profiler`.
@Suite struct CEFStackProfilerSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theBrowserProcessStartsWithTheStackProfilerOff(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("disable-stack-profiler"))
    }
}
