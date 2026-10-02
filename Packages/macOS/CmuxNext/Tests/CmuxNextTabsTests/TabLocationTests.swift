import Foundation
import Testing
@testable import CmuxNextTabs

/// The address a browser tab shows in the strip's location field: only web
/// pages have one, the host is the prominent part and everything after it
/// is the dimmed rest.
@MainActor @Suite struct TabLocationTests {
    private func location(_ address: String) throws -> TabLocation {
        try #require(TabLocation(address: address))
    }

    @Test func httpsSplitsHostFromTheDimmedRest() throws {
        let page = try location("https://github.com/manaflow-ai/cmux/pull/123?tab=files#diff")
        #expect(page.isSecure)
        #expect(page.displayHost == "github.com")
        #expect(page.displayRest == "/manaflow-ai/cmux/pull/123?tab=files#diff")
    }

    @Test func httpIsNotSecure() throws {
        let page = try location("http://example.com/a")
        #expect(!page.isSecure)
        #expect(page.displayHost == "example.com")
        #expect(page.displayRest == "/a")
    }

    @Test func aBareRootHasNoRest() throws {
        #expect(try location("https://example.com/").displayRest == "")
        #expect(try location("https://example.com").displayRest == "")
        #expect(try location("https://example.com/?q=1").displayRest == "/?q=1")
    }

    @Test func theHostIsLowercasedAndUserInfoIsNeverShown() throws {
        let page = try location("https://user:secret@Example.COM/Path")
        #expect(page.displayHost == "example.com")
        #expect(page.displayRest == "/Path")
        #expect(!(page.displayHost + page.displayRest).contains("secret"))
    }

    @Test func onlyANonDefaultPortIsShownWithTheHost() throws {
        #expect(try location("http://localhost:3000/app").displayHost == "localhost:3000")
        #expect(try location("https://localhost:8443/").displayHost == "localhost:8443")
        #expect(try location("https://example.com:443/").displayHost == "example.com")
        #expect(try location("http://example.com:80/").displayHost == "example.com")
        #expect(try location("http://[::1]:8080/x").displayHost == "[::1]:8080")
    }

    /// Internationalized domains stay in punycode, as the URL carries them,
    /// so a look-alike Unicode host cannot pose as another site.
    @Test func punycodeHostsStayPunycode() throws {
        #expect(try location("https://xn--bcher-kva.example/").displayHost == "xn--bcher-kva.example")
    }

    /// The tooltip and VoiceOver help show the full address, never the
    /// credentials in it.
    @Test func theDisplayURLDropsUserInfo() throws {
        let page = try location("https://user:secret@example.com/a?b=1#c")
        #expect(page.displayURL == "https://example.com/a?b=1#c")
        #expect(!page.displayURL.contains("user"))
        #expect(try location("http://example.com/x").displayURL == "http://example.com/x")
    }

    /// A percent-escaped host would decode into a look-alike
    /// (`%D0%B0` is Cyrillic а): such a page gets no location at all.
    @Test func percentEscapedOrNonASCIIHostsHaveNoLocation() {
        #expect(TabLocation(address: "https://%D0%B0pple.com/") == nil)
        #expect(TabLocation(page: URL(string: "https://ex%61mple.com/")) == nil)
    }

    @Test func internalPagesHaveNoLocation() {
        for address in ["about:blank", "chrome://newtab/", "cmux://settings", "file:///Users/me/a.html",
                        "data:text/plain,hi", "javascript:void(0)", "not a url", ""] {
            #expect(TabLocation(address: address) == nil, "\(address)")
        }
        #expect(TabLocation(address: nil) == nil)
        #expect(TabLocation(page: nil) == nil)
    }
}
