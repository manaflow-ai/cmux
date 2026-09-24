import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromeExtensionsManagerPageTests {
    @Test func omnibarLoadsExtensionsPageButLeavesOtherCmuxLinksToTheApp() {
        let resolver = BrowserURLResolver()
        #expect(resolver.navigableURL(from: "cmux://extensions")?.absoluteString == "cmux://extensions")
        #expect(resolver.navigableURL(from: "cmux://auth-callback?stack_refresh=x") == nil)
        #expect(resolver.navigableURL(from: "cmux://workspace/abc") == nil)
    }

    @Test func recognizesIconRequestsForValidIDsOnly() throws {
        let store = try #require(URL(string: "cmux://extensions/icon/bcjindcccaagfpapjjmafapmmgkkhgoa"))
        #expect(ChromeExtensionsManagerPage.iconExtensionID(for: store) == "bcjindcccaagfpapjjmafapmmgkkhgoa")
        let local = try #require(URL(string: "cmux://extensions/icon/local-1a2b3c4d-0000-4000-8000-000000000000"))
        #expect(ChromeExtensionsManagerPage.iconExtensionID(for: local) != nil)
        let traversal = try #require(URL(string: "cmux://extensions/icon/..%2F..%2Fetc"))
        #expect(ChromeExtensionsManagerPage.iconExtensionID(for: traversal) == nil)
        let otherHost = try #require(URL(string: "cmux://workspace/icon/bcjindcccaagfpapjjmafapmmgkkhgoa"))
        #expect(ChromeExtensionsManagerPage.iconExtensionID(for: otherHost) == nil)
    }

    @Test func decodesOnlyKnownRequestShapes() {
        #expect(ChromeExtensionsManagerPage.Request(messageBody: ["action": "snapshot"]) == .snapshot)
        #expect(ChromeExtensionsManagerPage.Request(messageBody: ["action": "setEnabled", "id": "x", "enabled": false]) == .setEnabled(id: "x", enabled: false))
        #expect(ChromeExtensionsManagerPage.Request(messageBody: ["action": "setEnabled", "id": "x"]) == nil)
        #expect(ChromeExtensionsManagerPage.Request(messageBody: ["action": "evaluate", "js": "1"]) == nil)
        #expect(ChromeExtensionsManagerPage.Request(messageBody: "snapshot") == nil)
    }

    @Test func pageForbidsFramingAndRemoteLoads() {
        let csp = ChromeExtensionsManagerPage.responseHeaders["Content-Security-Policy"] ?? ""
        #expect(csp.contains("frame-ancestors 'none'"))
        #expect(csp.contains("default-src 'none'"))
    }
}
