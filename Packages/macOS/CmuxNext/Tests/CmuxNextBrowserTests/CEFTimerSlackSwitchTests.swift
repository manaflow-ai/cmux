import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chrome's `kTimerSlackMac` (base/message_loop/message_pump_apple.mm) gives each Mac pump's delayed
/// timer the task's leeway; field trials turn it on in Chrome and cmux runs without them. It is on
/// only when the in-process pump gets CEF's delayed work as absolute run times (p14-energy-046): the
/// whole-millisecond path lost the leeway, so slack there only made wakes later.
@Suite struct CEFTimerSlackSwitchTests {
    @Test func absoluteRunTimesTurnOnTimerSlack() {
        let switches = CEFSwitches.current(forkAPIVersion: 27, absoluteDelayedRunTimes: true,
                                           bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(switches.arguments.filter { $0 == CEFSwitches.timerSlackFeature }.count == 1, "\(switches.arguments)")
    }

    @Test func theMillisecondPathKeepsItOff() {
        let switches = CEFSwitches.current(forkAPIVersion: 27, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.arguments.contains { $0.contains("TimerSlackMac") }, "\(switches.arguments)")
    }
}
