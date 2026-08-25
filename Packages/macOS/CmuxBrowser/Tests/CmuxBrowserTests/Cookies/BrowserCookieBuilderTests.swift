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
        #expect(cookie.domain == "example.test")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
    }

    @Test("preserves host-only cookies when the domain is omitted")
    func preservesHostOnlyCookie() throws {
        let originURL = try #require(URL(string: "https://example.test/"))
        let cookie = try #require(builder.makeCookie(
            name: "__Host-session",
            value: "secret",
            originURL: originURL,
            domain: nil,
            path: "/",
            secure: true,
            expires: nil,
            httpOnly: true
        ))
        let baseline = try #require(HTTPCookie(properties: [
            .name: "__Host-session",
            .value: "secret",
            .originURL: originURL,
            .path: "/",
            .secure: "TRUE",
        ]))

        #expect(cookie.domain == baseline.domain)
        #expect(cookie.path == "/")
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

    @Test("keeps HttpOnly secure cookies valid when the source URL is HTTP")
    func secureCookieUsesSecureParsingOrigin() throws {
        let originURL = try #require(URL(string: "http://example.test/"))
        let cookie = try #require(builder.makeCookie(
            name: "secure_session",
            value: "secret",
            originURL: originURL,
            domain: "example.test",
            path: "/",
            secure: true,
            expires: nil,
            httpOnly: true
        ))

        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
    }

    @Test("preserves an expiration while synthesizing the response header")
    func preservesExpiration() throws {
        let originURL = try #require(URL(string: "https://example.test/"))
        // Whole-second value: the synthesized `Expires` header has one-second resolution.
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let cookie = try #require(builder.makeCookie(
            name: "expiring_session",
            value: "secret",
            originURL: originURL,
            domain: "example.test",
            path: "/",
            secure: false,
            expires: expiration,
            httpOnly: true
        ))

        let actualExpiration = try #require(cookie.expiresDate)
        #expect(actualExpiration.timeIntervalSince1970 == expiration.timeIntervalSince1970)
        #expect(cookie.isHTTPOnly)
    }
}
