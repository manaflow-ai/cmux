import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium cookie write")
struct BrowserChromiumCookieWriteTests {
    private func cookie(_ properties: [HTTPCookiePropertyKey: Any]) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: properties))
    }

    @Test func domainCookieKeepsItsDomainAndExpiry() throws {
        let expires = Date(timeIntervalSince1970: 2_000_000_000)
        let write = try #require(BrowserChromiumCookieWrite(cookie: cookie([
            .name: "sid", .value: "secret", .domain: ".example.com", .path: "/app",
            .secure: "TRUE", .expires: expires,
        ])))
        #expect(write.url.absoluteString == "https://example.com/app")
        #expect(write.domain == ".example.com")
        #expect(write.secure)
        #expect(write.expires == expires)
        #expect(!write.description.contains("secret"))
    }

    @Test func hostOnlyCookieStaysHostOnlyAndSessionCookieHasNoExpiry() throws {
        let write = try #require(BrowserChromiumCookieWrite(cookie: cookie([
            .name: "a", .value: "1", .originURL: URL(string: "http://app.example.com/")!, .path: "/",
        ])))
        #expect(write.domain == "")
        #expect(write.url.absoluteString == "http://app.example.com/")
        #expect(write.expires == nil)
    }

    @Test func sameSiteMapsToCEFValues() throws {
        let lax = try #require(BrowserChromiumCookieWrite(cookie: cookie([
            .name: "a", .value: "1", .domain: "a.example", .path: "/", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
        ])))
        #expect(lax.sameSite == .lax)
        #expect(BrowserChromiumCookieWrite.SameSite.strict.rawValue == 3)
    }

    @Test func baseTimeIsMicrosecondsSince1601AsAString() {
        #expect(BrowserChromiumCookieWrite.baseTime(nil) == "0")
        #expect(BrowserChromiumCookieWrite.baseTime(Date(timeIntervalSince1970: 0)) == "11644473600000000")
    }

    @Test func shimJSONCarriesEveryFieldTheShimReads() throws {
        let write = BrowserChromiumCookieWrite(
            url: URL(string: "https://a.example/")!, name: "n", value: "v", domain: "", path: "/",
            secure: true, httpOnly: true, sameSite: .strict, expires: nil
        )
        let json = try BrowserChromiumCookieWrite.shimJSON([write])
        let list = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let entry = try #require(list.first)
        for key in ["url", "name", "value", "domain", "path", "secure", "httponly", "same_site", "has_expires", "expires", "creation", "last_access"] {
            #expect(entry[key] != nil, "missing \(key)")
        }
        #expect(entry["has_expires"] as? Bool == false)
        #expect(entry["same_site"] as? Int == 3)
    }

    @Test func resultParsesShimReply() {
        #expect(BrowserChromiumCookieWriteResult.parse(#"{"written":3,"rejected":1}"#) == BrowserChromiumCookieWriteResult(written: 3, rejected: 1))
        #expect(BrowserChromiumCookieWriteResult.parse("nope") == nil)
    }
}
