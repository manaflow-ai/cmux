@testable import CmuxNextBrowser
import Testing

/// A server's 401 on a Chromium tab (ask-2d244f2b2e): the shim's AUTH_PROMPT event (kind 52) carries the
/// token, the host and realm, and whether the page is https; the host asks with a credentials prompt.
@Suite struct CEFHTTPAuthEventTests {
    @Test func authPromptEventDecodes() {
        let event = CEFShimEvent(kind: 52, browser: 3, request: 9, a: 1, b: 0, s1: "example.com:8443", s2: "fixture")
        guard case .authPrompt(let browser, let token, let host, let realm, let isSecure) = event else {
            Issue.record("kind 52 did not decode to authPrompt: \(event)")
            return
        }
        #expect(browser == 3 && token == 9 && host == "example.com:8443" && realm == "fixture" && isSecure)
    }

    @Test func authPromptEventBelongsToItsBrowser() {
        let event = CEFShimEvent(kind: 52, browser: 3, request: 9, a: 0, b: 0, s1: "h", s2: "")
        #expect(event.browserID == 3)
    }
}
