import Foundation
import Testing
@testable import CmuxNextBrowser

/// p13-webui-020: Home had a Chromium spare renderer with no browser tab open (made for the pages
/// profile or an extension background page), and every page open replaced the browser profile's
/// spare. With the default-off feature `chromiumSpareAfterFirstTab` the browser process starts with
/// the fork's policy switch (a profile gets a spare only after one of its browser tabs navigated);
/// without it Chromium keeps its own policy. The spare has Chrome desktop's lifetime: no timeout switch.
@Suite struct CEFSpareRendererSwitchTests {
    private func switches(forkAPIVersion: Int32, spareAfterFirstTab: Bool) -> [String] {
        CEFSwitches.current(
            forkAPIVersion: forkAPIVersion,
            spareAfterFirstTab: spareAfterFirstTab,
            bundleIdentifier: "com.cmuxterm.app.next",
            environment: [:]
        ).arguments
    }

    @Test(arguments: [Int32(0), 27, 29])
    func theFeatureOnPassesThePolicyOnce(forkAPIVersion: Int32) {
        let arguments = switches(forkAPIVersion: forkAPIVersion, spareAfterFirstTab: true)
        #expect(arguments.filter { $0 == "cmux-spare-renderer-after-first-tab" }.count == 1, "\(arguments)")
    }

    @Test(arguments: [Int32(0), 27, 29])
    func theFeatureOffKeepsChromiumsOwnSpare(forkAPIVersion: Int32) {
        let arguments = switches(forkAPIVersion: forkAPIVersion, spareAfterFirstTab: false)
        #expect(!arguments.contains { $0.hasPrefix("cmux-spare-renderer") }, "\(arguments)")
    }

    @Test func theFeatureIsOffByDefault() {
        let arguments = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(!arguments.contains(CEFSwitches.spareRendererAfterFirstTab), "\(arguments)")
    }
}
