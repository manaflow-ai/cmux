@testable import CmuxNextBrowser
import Foundation
import Testing

/// WebKit cookies are built as Foundation cookies. An HttpOnly cookie goes
/// through a `Set-Cookie` header, since the property keys have no HttpOnly
/// (the old app's #10530: `cookies set --http-only` left the cookie readable
/// from page scripts).
@Suite struct BrowserCookieHTTPCookieTests {
    @Test func httpOnlySurvives() throws {
        // Whole seconds within the 400-day cap Set-Cookie parsing applies.
        let expires = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 30 * 86_400).rounded(.down))
        let cookie = BrowserCookie(name: "sid", value: "abc", domain: ".example.com", path: "/app", expires: expires,
                                   secure: true, httpOnly: true)
        let made = try #require(cookie.httpCookie)
        #expect(made.isHTTPOnly)
        #expect(made.isSecure)
        #expect(made.domain == ".example.com")
        #expect(made.path == "/app")
        #expect(made.expiresDate == expires)
    }

    @Test func aHostOnlyCookieStaysHostOnly() throws {
        let plain = BrowserCookie(name: "a", value: "1", domain: "app.example.com", path: "/", expires: nil, secure: false, httpOnly: false)
        let made = try #require(plain.httpCookie)
        #expect(made.domain == "app.example.com")
        #expect(!made.isHTTPOnly)
        #expect(made.isSessionOnly)
        let hidden = BrowserCookie(name: "b", value: "2", domain: "app.example.com", path: "/", expires: nil, secure: false, httpOnly: true)
        let parsed = try #require(hidden.httpCookie)
        #expect(parsed.domain == "app.example.com")
        #expect(parsed.isHTTPOnly)
    }

    @Test func unsafeFieldsMakeNoCookie() {
        for (name, value) in [("a;b", "1"), ("a", "1\r\nSet-Cookie: x=y"), ("a", "\u{7F}")] {
            let cookie = BrowserCookie(name: name, value: value, domain: "example.com", path: "/", expires: nil, secure: false, httpOnly: true)
            #expect(cookie.httpCookie == nil)
        }
    }
}
