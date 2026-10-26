import Foundation
import Testing
@testable import CmuxNextBrowser

/// p13-webui-020: Home had a Chromium spare renderer with no browser tab open (made for the pages
/// profile or an extension background page), and every page open replaced the browser profile's
/// spare. The browser process starts with the fork's policy switch: a profile gets a spare only
/// after one of its browser tabs navigated, and the spare lives as on Chrome desktop (no timeout).
@Suite struct CEFSpareRendererSwitchTests {
    @Test(arguments: [Int32(0), 27, 29])
    func everyBrowserProcessStartsWithTheSparePolicy(forkAPIVersion: Int32) {
        let arguments = CEFSwitches.current(
            forkAPIVersion: forkAPIVersion,
            bundleIdentifier: "com.cmuxterm.app.next",
            environment: [:]
        ).arguments
        #expect(arguments.filter { $0 == CEFSwitches.spareRendererAfterFirstTab }.count == 1, "\(arguments)")
    }

    @Test func theSpareHasNoTimeoutUntilAMeasurementSetsOne() {
        let arguments = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(!arguments.contains { $0.hasPrefix("cmux-spare-renderer-timeout-ms") }, "\(arguments)")
    }
}
