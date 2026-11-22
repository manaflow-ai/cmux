import Testing
@testable import CmuxNextBrowser

/// Who may give a Chromium page the keyboard, without starting CEF.
///
/// CEF focuses a page on its own after a navigation: the first load of a new
/// browser (the New Tab page) and every `LoadURL`. On macOS that activates
/// the page window, which then takes the keys from the new tab's omnibar
/// (dogfood nxdog13: desync W5 "a Chromium page window has the keys while
/// the model targets addressBar", 53 ms after the page attached, with no
/// focus request from cmux). A new tab's omnibar stays focused until the
/// user clicks the page; in cmux only the focus coordinator moves focus.
@MainActor
@Suite struct CEFFocusRequestTests {
    private func makeTab(lifecycleTrace: BrowserLifecycleTrace = BrowserLifecycleTrace()) -> CEFTab {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "focus"), profile: .default), runtime: runtime, lifecycleTrace: lifecycleTrace)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        return tab
    }

    @Test func aNavigationNeverFocusesThePageOnItsOwn() {
        let tab = makeTab()
        #expect(!tab.chromiumRequestsFocus(.navigation))
    }

    @Test func chromiumNeverFocusesThePageOnItsOwn() {
        let tab = makeTab()
        #expect(!tab.chromiumRequestsFocus(.system))
    }

    /// The focus coordinator gives the page focus through `setFocused(true)`:
    /// CEF asks back inside that call, and the request wins.
    @Test func cmuxsOwnFocusRequestWins() {
        let tab = makeTab()
        #expect(tab.withFocusGrant { tab.chromiumRequestsFocus(.system) })
        #expect(!tab.chromiumRequestsFocus(.system))
    }

    /// Requests reach the tab through the runtime; a browser cmux does not
    /// show (a popup before adoption) is refused.
    @Test func theRuntimeRoutesRequestsToTheTab() {
        let tab = makeTab()
        CEFRuntime.shared.register(tab, browser: 70_101)
        defer { CEFRuntime.shared.tabsByBrowser[70_101] = nil }
        #expect(!CEFRuntime.shared.focusRequested(browser: 70_101, source: CEFFocusSource.navigation.rawValue))
        #expect(tab.withFocusGrant { CEFRuntime.shared.focusRequested(browser: 70_101, source: CEFFocusSource.system.rawValue) })
        #expect(!CEFRuntime.shared.focusRequested(browser: 70_102, source: CEFFocusSource.system.rawValue))
    }

    /// Refusals reach the input journal (the live check of every New
    /// Browser Tab entry point reads them).
    @Test func aRefusalIsJournaled() {
        var events: [String] = []
        let tab = makeTab(lifecycleTrace: BrowserLifecycleTrace { _, event in events.append(event) })
        _ = tab.chromiumRequestsFocus(.navigation)
        #expect(events == ["focus-refused source=navigation"])
    }
}

/// Tab past a page's last element (CefFocusHandler::OnTakeFocus).
@MainActor
@Suite struct CEFTakeFocusTests {
    private final class Recorder: BrowserTabDelegate {
        var intents: [String] = []
        func browserTab(_ tab: any BrowserTab, didRequest intent: BrowserTabIntent) {
            intents.append(String(describing: intent))
        }
    }

    @Test func focusLeavingThePageAsksTheHostForTheOmnibar() {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "take"), profile: .default), runtime: runtime, lifecycleTrace: .shared)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        let recorder = Recorder()
        tab.delegate = recorder
        tab.handle(CEFShimEvent(kind: 31, browser: 1, request: 0, a: 1, b: 0, s1: "", s2: ""))
        tab.handle(CEFShimEvent(kind: 31, browser: 1, request: 0, a: 0, b: 0, s1: "", s2: ""))
        #expect(recorder.intents == ["takeFocus(forward: true)", "takeFocus(forward: false)"])
    }
}
