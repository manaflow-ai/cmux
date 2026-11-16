import Foundation
import Testing
@testable import CmuxNextBrowser

/// Leo 2026-11-15: "our chromium browser also has a bt of layout shif tfor some reason idk why".
/// Chromium followed the system's scroller style, which flips as Universal Control's shared mouse
/// leaves and returns; a classic scrollbar took its width from the page and the page reflowed. The
/// browser process starts with overlay scrollbars forced, so a page's width never depends on it.
@Suite struct CEFOverlayScrollbarSwitchTests {
    @Test(arguments: [0, 7, 27, 29])
    func pagesAlwaysDrawOverlayScrollbars(forkAPIVersion: Int32) {
        let switches = CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(switches.arguments.contains("enable-features=OverlayScrollbar:mode/overlay"))
    }
}
