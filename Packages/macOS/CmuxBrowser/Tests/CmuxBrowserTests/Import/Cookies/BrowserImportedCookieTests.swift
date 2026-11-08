import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Imported browser cookies")
struct BrowserImportedCookieTests {
    // 2027-11-08T15:54:15.176Z in milliseconds, as current Firefox-family cookie databases store it.
    private let expiryMilliseconds: Int64 = 1_825_694_055_176
    private let expiryDate = Date(timeIntervalSince1970: 1_825_694_055.176)

    private func firefoxRow(
        expiry: Int64 = 1_825_694_055_176,
        isHTTPOnly: Bool = false,
        sameSite: Int64 = 0,
        originAttributes: String = "",
        schemaVersion: Int64 = 17
    ) -> BrowserImportedCookie? {
        BrowserImportedCookie.firefox(
            host: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiry: expiry,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite,
            originAttributes: originAttributes,
            schemaVersion: schemaVersion
        )
    }

    private func chromiumRow(
        isHTTPOnly: Bool = false,
        sameSite: Int64 = -1,
        topFrameSiteKey: String = ""
    ) -> BrowserImportedCookie? {
        BrowserImportedCookie.chromium(
            host: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiresUTC: 13_407_167_655_176_000,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite,
            topFrameSiteKey: topFrameSiteKey
        )
    }

    @Test("reads a Firefox expiry stored in milliseconds")
    func firefoxMillisecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: expiryMilliseconds))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince(expiryDate)) < 1)
    }

    @Test("reads a Firefox expiry stored in seconds by cookie schema 15 and older")
    func firefoxSecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: 1_825_694_055, schemaVersion: 15))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince(expiryDate)) < 1)
    }

    @Test("reads a long-expired millisecond expiry as milliseconds")
    func firefoxSmallMillisecondExpiry() throws {
        let cookie = try #require(firefoxRow(expiry: 2_000_000_000, schemaVersion: 16))
        let expires = try #require(cookie.expiresDate)
        #expect(abs(expires.timeIntervalSince1970 - 2_000_000) < 1)
    }

    @Test("keeps a Firefox cookie HttpOnly")
    func firefoxHTTPOnly() throws {
        let cookie = try #require(firefoxRow(isHTTPOnly: true)?.makeHTTPCookie())
        #expect(cookie.isHTTPOnly)
    }

    @Test("keeps a Firefox cookie's SameSite attribute", arguments: [
        (Int64(0), BrowserImportedCookie.SameSite.none),
        (Int64(1), BrowserImportedCookie.SameSite.lax),
        (Int64(2), BrowserImportedCookie.SameSite.strict),
        (Int64(256), BrowserImportedCookie.SameSite.none),
    ])
    func firefoxSameSite(raw: Int64, expected: BrowserImportedCookie.SameSite) throws {
        let cookie = try #require(firefoxRow(sameSite: raw))
        #expect(cookie.sameSite == expected)
    }

    @Test("does not import a partitioned Firefox cookie as a first-party cookie")
    func firefoxPartitionedSkipped() {
        #expect(firefoxRow(originAttributes: "^partitionKey=%28https%2Cembedder.test%29") == nil)
        #expect(firefoxRow(originAttributes: "^userContextId=2&partitionKey=%28https%2Cembedder.test%29") == nil)
    }

    @Test("keeps a Chromium cookie HttpOnly")
    func chromiumHTTPOnly() throws {
        let cookie = try #require(chromiumRow(isHTTPOnly: true)?.makeHTTPCookie())
        #expect(cookie.isHTTPOnly)
    }

    @Test("keeps a Chromium cookie's SameSite attribute", arguments: [
        (Int64(-1), BrowserImportedCookie.SameSite.none),
        (Int64(0), BrowserImportedCookie.SameSite.none),
        (Int64(1), BrowserImportedCookie.SameSite.lax),
        (Int64(2), BrowserImportedCookie.SameSite.strict),
    ])
    func chromiumSameSite(raw: Int64, expected: BrowserImportedCookie.SameSite) throws {
        let cookie = try #require(chromiumRow(sameSite: raw))
        #expect(cookie.sameSite == expected)
    }

    @Test("does not import a partitioned Chromium cookie as a first-party cookie")
    func chromiumPartitionedSkipped() {
        #expect(chromiumRow(topFrameSiteKey: "https://embedder.test") == nil)
    }

    @Test("writes SameSite to the WebKit cookie", arguments: [
        (BrowserImportedCookie.SameSite.lax, false),
        (BrowserImportedCookie.SameSite.strict, false),
        (BrowserImportedCookie.SameSite.lax, true),
    ])
    func httpCookieSameSite(sameSite: BrowserImportedCookie.SameSite, isHTTPOnly: Bool) throws {
        let imported = BrowserImportedCookie(
            domain: ".example.test",
            name: "session",
            value: "abc",
            path: "/",
            expiresDate: expiryDate,
            isSecure: true,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite
        )
        let cookie = try #require(imported.makeHTTPCookie())
        let expected: HTTPCookieStringPolicy = sameSite == .strict ? .sameSiteStrict : .sameSiteLax
        #expect(cookie.sameSitePolicy == expected)
        #expect(cookie.isHTTPOnly == isHTTPOnly)
        #expect(cookie.domain == ".example.test")
        #expect(cookie.isSecure)
    }

    @Test("leaves a cookie with no SameSite attribute without a policy")
    func httpCookieNoSameSite() throws {
        let cookie = try #require(firefoxRow(sameSite: 0)?.makeHTTPCookie())
        #expect(cookie.sameSitePolicy == nil)
        #expect(!cookie.isHTTPOnly)
    }
}
