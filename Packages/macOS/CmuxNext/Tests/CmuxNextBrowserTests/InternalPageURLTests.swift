import Foundation
import Testing
@testable import CmuxNextBrowser

/// Typed Chromium internal pages resolve to Chromium's canonical URL
/// (GURL's standard-URL canonicalization; `about:` aliases as
/// `url_formatter::FixupURL` maps them), so every spelling of a page loads,
/// highlights and matches history the same way.
@Suite struct InternalPageURLTests {
    private let chromium = BrowserURLResolver(homeDirectory: URL(filePath: "/Users/test"), allowsChromiumSchemes: true)
    private let webKit = BrowserURLResolver(homeDirectory: URL(filePath: "/Users/test"), allowsChromiumSchemes: false)

    nonisolated static let canonical: [(typed: String, expected: String)] = [
        ("chrome://extensions", "chrome://extensions/"),
        ("chrome://extensions/", "chrome://extensions/"),
        ("CHROME://Extensions", "chrome://extensions/"),
        ("Chrome://EXTENSIONS/", "chrome://extensions/"),
        ("chrome://extensions/?id=abc", "chrome://extensions/?id=abc"),
        ("chrome://extensions?id=abc", "chrome://extensions/?id=abc"),
        ("chrome://extensions#details", "chrome://extensions/#details"),
        ("chrome:extensions", "chrome://extensions/"),
        ("chrome://settings/passwords", "chrome://settings/passwords"),
        ("chrome://Settings/Passwords", "chrome://settings/Passwords"),
        ("chrome://version", "chrome://version/"),
        ("chrome://gpu", "chrome://gpu/"),
        ("chrome://net-internals/#dns", "chrome://net-internals/#dns"),
        ("about:extensions", "chrome://extensions/"),
        ("ABOUT:Version", "chrome://version/"),
        ("about:settings/passwords", "chrome://settings/passwords"),
        ("about:flags?x=1", "chrome://flags/?x=1"),
        ("about:blank", "about:blank"),
        ("About:Blank", "about:blank"),
        ("chrome-extension://abcdefghijklmnopabcdefghijklmnop", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"),
        ("chrome-extension://ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP/options.html",
         "chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html"),
    ]

    @Test(arguments: canonical)
    func chromiumTabsLoadTheCanonicalURL(_ row: (typed: String, expected: String)) {
        #expect(chromium.url(for: row.typed)?.absoluteString == row.expected)
    }

    @Test func everySpellingOfAPageIsOneURL() {
        let spellings = ["chrome://extensions", "chrome://extensions/", "CHROME://Extensions", "about:extensions", "chrome:extensions"]
        #expect(Set(spellings.compactMap { chromium.url(for: $0)?.absoluteString }) == ["chrome://extensions/"])
    }

    /// Not internal pages: searched, as before.
    @Test(arguments: ["chrome://", "chrome:", "about:", "chrome://user@extensions", "chrome-extension://"])
    func malformedInternalURLsAreSearched(_ typed: String) {
        #expect(chromium.url(for: typed) == nil)
    }

    /// WebKit tabs cannot show Chromium pages; only about:blank loads there.
    @Test(arguments: ["chrome://extensions", "chrome://extensions/", "about:extensions", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
    func webKitTabsSearchChromiumPages(_ typed: String) {
        #expect(webKit.url(for: typed) == nil)
    }

    @Test func typedTextNamesAChromiumPageOnlyForItsSchemes() {
        #expect(ChromiumInternalURL(typed: "About:Extensions")?.url.absoluteString == "chrome://extensions/")
        #expect(ChromiumInternalURL(typed: "chrome://extensions")?.url.absoluteString == "chrome://extensions/")
        #expect(ChromiumInternalURL(typed: "about:blank") == nil)
        #expect(ChromiumInternalURL(typed: "https://example.com") == nil)
        #expect(ChromiumInternalURL(typed: "extensions") == nil)
    }

    @Test func onlyChromiumSchemesNeedChromium() throws {
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "chrome://extensions/"))))
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "chrome-extension://abc/x.html"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "about:blank"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "https://example.com/"))))
    }

    @Test func webKitTabsStillLoadAboutBlank() {
        #expect(webKit.url(for: "About:Blank")?.absoluteString == "about:blank")
    }
}
