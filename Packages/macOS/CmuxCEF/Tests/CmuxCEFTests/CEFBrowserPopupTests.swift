import CoreGraphics
import Foundation
import Testing
@testable import CmuxCEF

@Suite
struct CEFBrowserPopupTests {
    /// `browser click` and `browser eval` run through `Runtime.evaluate`.
    /// Without a user gesture Chromium's popup blocker refused the click's
    /// `window.open` (it returned null and no tab opened); WebKit runs the
    /// app's scripts as a user gesture (`evaluateJavaScript`).
    @Test
    func appScriptsRunAsAUserGestureSoTheyCanOpenPopups() throws {
        let params = CEFBrowser.evaluateParams("document.querySelector('#pop').click()")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any]
        )
        #expect(object["userGesture"] as? Bool == true)
        #expect(object["expression"] as? String == "document.querySelector('#pop').click()")
        #expect(object["returnByValue"] as? Bool == true)
        #expect(object["awaitPromise"] as? Bool == true)
    }

    @MainActor @Test
    func createdPopupTargetURLSeedsTheAdoptedBrowserState() throws {
        let runtime = CEFRuntime(layout: nil)
        let opener = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "https://example.com/")),
            runtime: runtime
        )
        let target = try #require(URL(string: "https://chromewebstore.google.com/detail/example"))

        let popup = CEFBrowser(adopting: 42, from: opener, runtime: runtime, targetURL: target)

        #expect(popup.state.url == target)
        #expect(popup.configuration.initialURL == nil)
    }

    /// A sized `window.open` popup arrives (AFTER_CREATED, window 0) before
    /// Chromium asked where to put it (the popup window request, with the
    /// page's size) and inserted it. Handed over then, it had no features
    /// (cmux's popup window opened at its default size) and moving it into a
    /// window of its own failed ("could not move into its own window"), so
    /// the popup closed. The runtime hands it over once Chromium inserted it.
    @MainActor @Test
    func anUnplacedPopupIsHandedOverOnceChromiumInsertedIt() async throws {
        let runtime = CEFRuntime(layout: nil)
        let opener = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "https://example.com/")),
            runtime: runtime
        )
        runtime.register(opener, id: 7)
        var opened: [(CEFBrowser, CEFDisposition, CGRect?, Bool)] = []
        opener.onEvent = { event in
            if case .newBrowser(let popup, let disposition, let features, let gesture) = event {
                opened.append((popup, disposition, features, gesture))
            }
        }
        let target = "https://example.com/sized"

        runtime.handle(.popup(browser: 7, url: target, disposition: 5, userGesture: true))
        runtime.handle(.afterCreated(browser: 42, request: 0, window: 0,
                                     created: CEFCreatedBy(opener: 7, disposition: .unknown, features: nil)))
        #expect(runtime.windowRequest(kind: 2, disposition: 5, source: 7, url: target,
                                      bounds: CGRect(x: 10, y: 20, width: 480, height: 360)) == 7)
        await Task { @MainActor in }.value
        #expect(opened.isEmpty)

        runtime.handle(.tab(.inserted, browser: 42, window: 9, value: 0))
        await Task { @MainActor in }.value

        let popup = try #require(opened.first)
        #expect(popup.0.state.url?.absoluteString == target)
        #expect(popup.1 == .newPopup)
        #expect(popup.2 == CGRect(x: 10, y: 20, width: 480, height: 360))
        #expect(popup.3)
        #expect(runtime.browser(id: 42) === popup.0)
    }

    /// `window.close()` in a popup (or its opener's `popup.close()`) has
    /// Chromium destroy the page without a close request: the popup's tab
    /// or popup window stayed open around a dead page. A page Chromium
    /// destroyed on its own asks its owner to close it; one cmux closed
    /// does not.
    @MainActor @Test
    func aPageChromiumClosedAsksItsOwnerToClose() {
        let runtime = CEFRuntime(layout: nil)
        func page(_ id: Int32) -> (CEFBrowser, () -> [String]) {
            let browser = CEFBrowser(
                configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "https://example.com/")),
                runtime: runtime
            )
            runtime.register(browser, id: id)
            var events: [String] = []
            browser.onEvent = { event in
                switch event {
                case .closeRequested: events.append("closeRequested")
                case .closed: events.append("closed")
                default: break
                }
            }
            return (browser, { events })
        }

        let (byPage, pageEvents) = page(1)
        byPage.browserDidClose()
        #expect(pageEvents() == ["closeRequested", "closed"])

        let (byCmux, cmuxEvents) = page(2)
        byCmux.close()
        byCmux.browserDidClose()
        #expect(cmuxEvents() == ["closed"])
    }

    /// A tab Chromium opens from a WebUI page (chrome://extensions' "Chrome
    /// Web Store" link) or by a modified click can load before Chromium
    /// inserts it: its address, title and loading events reached no page,
    /// so the adopted tab stayed "New tab" with a spinner. They are kept
    /// for the tab and applied when it is handed over.
    @MainActor @Test
    func eventsBeforeAnUnplacedTabIsHandedOverAreKept() async throws {
        let runtime = CEFRuntime(layout: nil)
        let opener = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "chrome://extensions/")),
            runtime: runtime
        )
        runtime.register(opener, id: 7)
        var opened: [CEFBrowser] = []
        opener.onEvent = { event in
            if case .newBrowser(let popup, _, _, _) = event { opened.append(popup) }
        }
        let store = "https://chromewebstore.google.com/category/extensions"

        runtime.handle(.popup(browser: 7, url: store, disposition: 3, userGesture: true))
        runtime.handle(.afterCreated(browser: 43, request: 0, window: 0,
                                     created: CEFCreatedBy(opener: 7, disposition: .unknown, features: nil)))
        runtime.handle(.loadingState(browser: 43, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.address(browser: 43, url: store))
        runtime.handle(.title(browser: 43, title: "Chrome Web Store"))
        runtime.handle(.loadingState(browser: 43, loading: false, canGoBack: false, canGoForward: false))
        runtime.handle(.tab(.inserted, browser: 43, window: 9, value: 0))
        await Task { @MainActor in }.value

        let popup = try #require(opened.first)
        #expect(popup.state.url?.absoluteString == store)
        #expect(popup.state.title == "Chrome Web Store")
        #expect(!popup.state.isLoading)
    }

    @Test
    func afterCreatedEventCarriesThePopupTargetURL() throws {
        let event = CEFShimEvent(
            kind: 2,
            browser: 42,
            request: 0,
            a: 0,
            b: (Int64(7) << 32) | (Int64(1) << 16) | Int64(3),
            s1: "",
            s2: "https://chromewebstore.google.com/detail/example"
        )

        guard case .afterCreated(_, _, _, let created) = event else {
            Issue.record("Expected AFTER_CREATED event")
            return
        }
        #expect(created.url == "https://chromewebstore.google.com/detail/example")
        #expect(created.opener == 7)
        #expect(created.disposition == .newForegroundTab)
        #expect(created.userGesture)
    }
}
