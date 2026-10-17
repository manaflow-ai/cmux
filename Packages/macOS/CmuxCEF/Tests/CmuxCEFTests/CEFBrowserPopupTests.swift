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
