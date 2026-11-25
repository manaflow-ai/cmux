import Foundation
import Testing
@testable import CmuxNextBrowser

/// Renderer sharing for agent chats (HQ#7577): every agent chat is cmux-page://cmux.agent/, and each
/// held its own renderer (100 idle chats: 107 renderers, 17.5 GB). The browser process names the
/// first-party page scheme so the fork gives it one renderer per site, as Chrome's NTP has.
@Suite struct CEFPageProcessPerSiteSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theBrowserProcessNamesThePageSchemeForProcessPerSite(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("cmux-process-per-site-schemes=cmux-page"))
    }

    @Test func webPagesKeepChromesProcessModel() {
        let switches = CEFSwitches.current(forkAPIVersion: 30, bundleIdentifier: "com.cmuxterm.app.next", environment: [:])
        #expect(!switches.arguments.contains("process-per-site"))
    }
}
