import Foundation
import Testing
@testable import CmuxNextBrowser

/// p08-startup-099: while the app's `CMUX_TRACE_STARTUP` records, Chromium's browser process starts with Chrome's
/// startup tracing switches (components/tracing/common/tracing_switches.cc) and writes its file beside the app's;
/// with the variable unset the switch builder adds no tracing switch.
@Suite struct CEFStartupTraceSwitchTests {
    private static let traceSwitchPrefix = "trace-startup"

    private func arguments(_ trace: ChromiumStartupTrace?) -> [String] {
        CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:],
                            startupTrace: trace).arguments
    }

    @Test func unsetAddsNoSwitch() {
        let unset = arguments(nil)
        #expect(!unset.contains { $0.hasPrefix(Self.traceSwitchPrefix) }, "\(unset)")
        let byDefault = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(!byDefault.contains { $0.hasPrefix(Self.traceSwitchPrefix) }, "\(byDefault)")
    }

    @Test func aTraceAddsChromesStartupTracingSwitchesOnce() {
        let trace = ChromiumStartupTrace(seconds: 4, file: URL(fileURLWithPath: "/tmp/startup dir/startup-cef.json"))
        let tracing = arguments(trace).filter { $0.hasPrefix(Self.traceSwitchPrefix) }
        #expect(tracing == ["trace-startup", "trace-startup-duration=4", "trace-startup-file=/tmp/startup dir/startup-cef.json",
                            "trace-startup-format=json"])
    }

    @Test func theDurationIsAtLeastOneSecond() {
        let trace = ChromiumStartupTrace(seconds: 0, file: URL(fileURLWithPath: "/tmp/startup-cef.json"))
        #expect(arguments(trace).contains("trace-startup-duration=1"))
    }
}
