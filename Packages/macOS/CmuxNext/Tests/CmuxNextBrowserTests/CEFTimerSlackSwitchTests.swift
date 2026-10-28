import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chrome's `kTimerSlackMac` (base/message_loop/message_pump_apple.mm, message_pump_kqueue.cc) gives each
/// CFRunLoop and kqueue pump's delayed timer the task's leeway; field trials turn it on in Chrome and cmux
/// runs without them. The UI thread's MessagePumpExternal arms no base timer, so the flag changes only
/// renderer, GPU and utility processes and the browser's non-UI threads: it is the default-off feature
/// `cefTimerSlack`, never a side effect of the fork's absolute run times.
@Suite struct CEFTimerSlackSwitchTests {
    @Test func theFeatureTurnsOnTimerSlack() {
        let switches = CEFSwitches.current(forkAPIVersion: 27, chromiumFeatures: ["TimerSlackMac"],
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        let features = CEFSwitchesWakeUpAlignmentTests.enabledFeatures(switches.arguments)
        #expect(features.filter { $0 == "TimerSlackMac" }.count == 1, "\(switches.arguments)")
    }

    @Test func withoutTheFeatureItStaysOff() {
        let switches = CEFSwitches.current(forkAPIVersion: 27, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.arguments.contains { $0.contains("TimerSlackMac") }, "\(switches.arguments)")
    }

    @Test func chromiumFeaturesShareOneEnableEntry() {
        let switches = CEFSwitches.current(forkAPIVersion: 27, chromiumFeatures: ["TimerSlackMac", "AlignWakeUps"],
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        let entries = switches.arguments.filter { $0.hasPrefix("enable-features=") }
        #expect(entries.count == 1, "\(switches.arguments)")
        let features = CEFSwitchesWakeUpAlignmentTests.enabledFeatures(entries)
        #expect(features.contains("TimerSlackMac"), "\(switches.arguments)")
        #expect(features.filter { $0 == "AlignWakeUps" }.count == 1, "\(switches.arguments)")
    }
}
