import Foundation
import Testing
@testable import CmuxNextBrowser

/// Lawrence (2026-10-23): splits lag more with Chromium pages. Chromium's UI thread is the app's
/// main thread, and one `CefDoMessageLoopWork` pass ran ready work for up to CEF's 10 ms slice:
/// longer than a 120 Hz frame (8.33 ms), so a pass during a motion dropped the frame. The browser
/// process starts with the fork's `--cmux-pump-time-slice-us` at a quarter of a frame.
@Suite struct CEFPumpTimeSliceSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func onePumpPassIsShorterThanADisplayFrame(bundle: String) throws {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: bundle, environment: [:])
        let value = try #require(switches.arguments.first { $0.hasPrefix("cmux-pump-time-slice-us=") }, "\(switches.arguments)")
        let microseconds = try #require(Int(value.dropFirst("cmux-pump-time-slice-us=".count)))
        #expect(microseconds >= 100 && microseconds * 4 <= 8_333, "a pass leaves most of a 120 Hz frame: \(microseconds) us")
    }
}
