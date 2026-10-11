import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL cookie URL match")
struct BrowserReplCookieMatchTests {
    private func cookie(path: String, domain: String = "example.com", secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "sid", .value: "1", .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test(
        "A cookie's path matches its own path and the paths below it (RFC 6265 path-match)",
        arguments: [
            ("/account", "/account", true),
            ("/account", "/account/", true),
            ("/account", "/account/settings", true),
            ("/account/", "/account/settings", true),
            ("/account/", "/account/", true),
            ("/", "/anything", true),
            ("/account", "/accounting", false),
            ("/account", "/account-admin/x", false),
            ("/account/", "/account", false),
            ("/account", "/", false),
        ]
    )
    func pathMatch(cookiePath: String, requestPath: String, matches: Bool) throws {
        let url = try #require(URL(string: "https://example.com" + requestPath))
        #expect(try cookie(path: cookiePath).browserReplMatches(url) == matches)
    }

    @Test("Domain and Secure rules still apply")
    func domainAndSecure() throws {
        let parent = try cookie(path: "/", domain: ".example.com")
        #expect(parent.browserReplMatches(try #require(URL(string: "https://app.example.com/x"))))
        #expect(!parent.browserReplMatches(try #require(URL(string: "https://example.org/x"))))
        let secure = try cookie(path: "/", secure: true)
        #expect(!secure.browserReplMatches(try #require(URL(string: "http://example.com/"))))
        #expect(try cookie(path: "/", domain: "localhost", secure: true).browserReplMatches(try #require(URL(string: "http://localhost:3000/"))))
    }
}
