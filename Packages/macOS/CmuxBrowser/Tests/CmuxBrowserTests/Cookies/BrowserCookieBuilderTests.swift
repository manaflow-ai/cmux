import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser cookie builder")
struct BrowserCookieBuilderTests {
    private let builder = BrowserCookieBuilder()

    @Test("preserves the requested HttpOnly attribute")
    func preservesHTTPOnlyAttribute() throws {
        let originURL = try #require(URL(string: "https://example.test/dashboard"))
        let cookie = try #require(builder.makeCookie(
            name: "session",
            value: "secret",
            originURL: originURL,
            domain: "example.test",
            path: "/",
            secure: true,
            expires: nil,
            httpOnly: true
        ))

        #expect(cookie.name == "session")
        #expect(cookie.value == "secret")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
    }

    @Test("leaves ordinary cookies script-readable")
    func leavesOrdinaryCookiesScriptReadable() throws {
        let originURL = try #require(URL(string: "https://example.test/"))
        let cookie = try #require(builder.makeCookie(
            name: "preference",
            value: "light",
            originURL: originURL,
            domain: "example.test",
            path: "/",
            secure: false,
            expires: nil,
            httpOnly: false
        ))

        #expect(!cookie.isHTTPOnly)
    }
}
