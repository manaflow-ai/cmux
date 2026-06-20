import Foundation
import Testing
@testable import CmuxBrowser

/// A stub awaiter for constructing the repository in tests. The cookie wire
/// mapping and cookie materialization paths under test never reach the store
/// I/O, so the stub is never invoked; the store-touching methods need a live
/// `WKHTTPCookieStore` and main-loop pumping and are exercised via the live
/// `browser cookies.*` socket sweep rather than in-process.
private struct NeverAwaiter: BrowserCookieStoreAwaiting {
    func await<T>(
        timeout: TimeInterval,
        start: (@escaping @Sendable (T) -> Void) -> Void
    ) -> T? {
        nil
    }
}

@Suite("BrowserCookieRepository wire mapping")
struct BrowserCookieRepositoryTests {
    let repository = BrowserCookieRepository(awaiter: NeverAwaiter())

    @Test("cookieDictionary encodes a persistent cookie with integer expiry")
    func cookieDictionaryPersistent() throws {
        let expires = Date(timeIntervalSince1970: 1_700_000_000)
        let cookie = try #require(HTTPCookie(properties: [
            .name: "sid",
            .value: "abc",
            .domain: "example.com",
            .path: "/app",
            .secure: "TRUE",
            .expires: expires
        ]))
        let dict = repository.cookieDictionary(from: cookie)
        #expect(dict["name"] as? String == "sid")
        #expect(dict["value"] as? String == "abc")
        #expect(dict["domain"] as? String == "example.com")
        #expect(dict["path"] as? String == "/app")
        #expect(dict["secure"] as? Bool == true)
        #expect(dict["session_only"] as? Bool == false)
        #expect(dict["expires"] as? Int == 1_700_000_000)
    }

    @Test("cookieDictionary encodes a session cookie as NSNull expiry")
    func cookieDictionarySession() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "tmp",
            .value: "1",
            .domain: "example.com",
            .path: "/"
        ]))
        let dict = repository.cookieDictionary(from: cookie)
        #expect(dict["session_only"] as? Bool == true)
        #expect(dict["expires"] is NSNull)
    }

    @Test("cookie materializes from a raw row, filling path and domain fallbacks")
    func cookieFromRawFallbacks() throws {
        let fallback = URL(string: "https://fallback.example/page")
        let cookie = try #require(repository.cookie(
            from: ["name": "k", "value": "v"],
            fallbackURL: fallback
        ))
        #expect(cookie.name == "k")
        #expect(cookie.value == "v")
        #expect(cookie.domain == "fallback.example")
        #expect(cookie.path == "/")
    }

    @Test("cookie reads integer expires and secure flag")
    func cookieFromRawExpiresInt() throws {
        let cookie = try #require(repository.cookie(
            from: [
                "name": "k",
                "value": "v",
                "domain": "explicit.example",
                "path": "/p",
                "secure": true,
                "expires": 1_700_000_000
            ],
            fallbackURL: nil
        ))
        #expect(cookie.domain == "explicit.example")
        #expect(cookie.path == "/p")
        #expect(cookie.isSecure)
        let expires = try #require(cookie.expiresDate)
        #expect(Int(expires.timeIntervalSince1970) == 1_700_000_000)
    }
}
