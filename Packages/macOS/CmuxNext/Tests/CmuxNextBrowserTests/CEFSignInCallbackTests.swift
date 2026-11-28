import Foundation
import Testing
@testable import CmuxNextBrowser

/// The shim reports a sign-in tab's stopped callback (`CMUX_SHIM_AUTH_CALLBACK`)
/// to that tab.
@Suite struct CEFSignInCallbackTests {
    @Test func theAuthCallbackEventDecodesForItsBrowser() {
        let event = CEFShimEvent(kind: 37, browser: 12, request: 0, a: 1, b: 0, s1: "myapp://done?code=1", s2: "")
        #expect(event == .authCallback(browser: 12, url: "myapp://done?code=1"))
        #expect(event.browserID == 12)
    }
}
