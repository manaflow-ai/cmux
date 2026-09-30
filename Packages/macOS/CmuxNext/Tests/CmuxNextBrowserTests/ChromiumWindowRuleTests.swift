import Testing
@testable import CmuxNextBrowser

/// The last-resort guard: a top-level Chromium window with a title bar never
/// stays on screen, whatever opened it. Child windows (pages, docked DevTools,
/// bubbles, menus, extension popups), borderless overlays (video
/// picture-in-picture) and DevTools windows cmux placed stay.
@Suite struct ChromiumWindowRuleTests {
    private func facts(chromium: Bool = true, browser: Bool = false, parent: Bool = false,
                       titled: Bool = true, visible: Bool = true, devTools: Bool = false,
                       floating: Bool = false) -> ChromiumWindowFacts {
        ChromiumWindowFacts(chromium: chromium, browserWindow: browser, hasParent: parent,
                            titled: titled, visible: visible, devTools: devTools, floating: floating)
    }

    @Test func aChromiumBrowserWindowIsHidden() {
        #expect(ChromiumWindowRule.verdict(facts(browser: true)) == .hide)
    }

    @Test func aChromiumDialogWindowIsClosed() {
        // Task Manager, "Report an issue", the profile picker.
        #expect(ChromiumWindowRule.verdict(facts()) == .close)
    }

    @Test func pagesBubblesAndOverlaysStay() {
        #expect(ChromiumWindowRule.verdict(facts(browser: true, parent: true)) == .allow)
        #expect(ChromiumWindowRule.verdict(facts(parent: true, titled: false)) == .allow)
        #expect(ChromiumWindowRule.verdict(facts(titled: false)) == .allow)
        // Document picture-in-picture floats on purpose.
        #expect(ChromiumWindowRule.verdict(facts(browser: true, floating: true)) == .allow)
    }

    @Test func cmuxWindowsAndPlacedDevToolsStay() {
        #expect(ChromiumWindowRule.verdict(facts(chromium: false)) == .allow)
        #expect(ChromiumWindowRule.verdict(facts(devTools: true)) == .allow)
        #expect(ChromiumWindowRule.verdict(facts(browser: true, visible: false)) == .allow)
    }
}
