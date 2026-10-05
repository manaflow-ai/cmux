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

    /// Only a loopback address is a potentially trustworthy http origin: a
    /// name that starts with `127.` is any host its domain's owner points it
    /// at, and a spelling the system resolver reads as another address
    /// (`0177.0.0.1` is 177.0.0.1 to `getaddrinfo`) is not one either.
    @Test("A Secure cookie goes over http to 127.0.0.0/8, not to a host named 127.*")
    func secureCookieLoopbackIsByAddress() throws {
        let parent = try cookie(path: "/", domain: ".example.com", secure: true)
        #expect(!parent.browserReplMatches(try #require(URL(string: "http://127.example.com/"))))
        #expect(!parent.browserReplMatches(try #require(URL(string: "http://127.0.0.1.example.com/"))))
        #expect(!(try cookie(path: "/", domain: "0177.0.0.1", secure: true)).browserReplMatches(try #require(URL(string: "http://0177.0.0.1/"))))
        #expect(!(try cookie(path: "/", domain: "127.999.0.1", secure: true)).browserReplMatches(try #require(URL(string: "http://127.999.0.1/"))))
        #expect(try cookie(path: "/", domain: "127.0.0.1", secure: true).browserReplMatches(try #require(URL(string: "http://127.0.0.1:8080/"))))
        #expect(try cookie(path: "/", domain: "127.4.5.6", secure: true).browserReplMatches(try #require(URL(string: "http://127.4.5.6/"))))
    }

    @Test("The domain policy's loopback is 127.0.0.0/8 by address too")
    func policyLoopbackIsByAddress() {
        #expect(BrowserReplHostName.isLoopback("127.0.0.1"))
        #expect(BrowserReplHostName.isLoopback("127.255.0.9"))
        #expect(BrowserReplHostName.isLoopback("[::1]"))
        #expect(BrowserReplHostName.isLoopback("localhost"))
        #expect(!BrowserReplHostName.isLoopback("127.999.0.1"))
        #expect(!BrowserReplHostName.isLoopback("127.0.0.01"))
        #expect(!BrowserReplHostName.isLoopback("127.example.com"))
    }
}
