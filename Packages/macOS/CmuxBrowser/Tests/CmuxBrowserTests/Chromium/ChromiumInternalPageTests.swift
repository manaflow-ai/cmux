import Foundation
import Testing

@testable import CmuxBrowser

@Suite struct ChromiumInternalURLTests {
    @Test(arguments: [
        ("chrome://extensions", "chrome://extensions/"),
        ("CHROME://Extensions/", "chrome://extensions/"),
        ("chrome:extensions", "chrome://extensions/"),
        ("chrome:///version", "chrome://version/"),
        ("chrome://extensions?id=abc", "chrome://extensions/?id=abc"),
        ("chrome://settings/content", "chrome://settings/content"),
        ("about:flags", "chrome://flags/"),
        ("About:Version", "chrome://version/"),
        ("chrome-extension://abcdef/popup.html", "chrome-extension://abcdef/popup.html"),
    ])
    func canonicalizesEverySpelling(typed: String, expected: String) {
        #expect(ChromiumInternalURL(typed: typed)?.url.absoluteString == expected)
    }

    @Test(arguments: [
        "about:blank", "about:srcdoc", "about:blank#x", "https://example.com", "chrome://",
        "chrome://user@host/", "chrome://host:80/", "chrome://ex ample/", "extensions", "javascript:alert(1)",
    ])
    func refusesNonInternalText(_ typed: String) {
        #expect(ChromiumInternalURL(typed: typed) == nil)
    }

    @Test func needsChromiumOnlyForChromiumSchemes() throws {
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "chrome://version/"))))
        #expect(ChromiumInternalURL.needsChromium(try #require(URL(string: "CHROME-EXTENSION://id/x.html"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "about:blank"))))
        #expect(!ChromiumInternalURL.needsChromium(try #require(URL(string: "https://example.com"))))
    }
}

@Suite struct ChromiumPageRouteTests {
    @Test func settingsRootOpensCmuxSettings() {
        #expect(ChromiumPageRoute(typed: "chrome://settings") == .browserSettings)
        #expect(ChromiumPageRoute(typed: "about:settings") == .browserSettings)
        #expect(ChromiumPageRoute(typed: " CHROME://Settings/ ") == .browserSettings)
    }

    @Test func settingsSectionsAndOtherPagesStayChromium() throws {
        #expect(ChromiumPageRoute(typed: "chrome://settings/content")
            == .chromium(try #require(URL(string: "chrome://settings/content"))))
        #expect(ChromiumPageRoute(typed: "chrome://history")
            == .chromium(try #require(URL(string: "chrome://history/"))))
        #expect(ChromiumPageRoute(typed: "chrome:extensions")
            == .chromium(try #require(URL(string: "chrome://extensions/"))))
    }

    @Test func nonInternalTextHasNoRoute() {
        #expect(ChromiumPageRoute(typed: "example.com") == nil)
        #expect(ChromiumPageRoute(typed: "about:blank") == nil)
    }

    @Test func completesPageNamesOnlyInChromiumPanels() {
        let rows = ChromiumPageRoute.completions(for: "chrome://ex", allowsChromiumSchemes: true)
        #expect(rows.map(\.absoluteString) == ["chrome://extensions/"])
        #expect(ChromiumPageRoute.completions(for: "about:", allowsChromiumSchemes: true).count
            == ChromiumPageRoute.completedHosts.count)
        #expect(ChromiumPageRoute.completions(for: "chrome:", allowsChromiumSchemes: true).first?.absoluteString
            == "chrome://extensions/")
        #expect(ChromiumPageRoute.completions(for: "chrome://ex", allowsChromiumSchemes: false).isEmpty)
        #expect(ChromiumPageRoute.completions(for: "chrome://extensions/x", allowsChromiumSchemes: true).isEmpty)
        #expect(ChromiumPageRoute.completions(for: "extensions", allowsChromiumSchemes: true).isEmpty)
    }

    @Test func internalAddressesAreNeverSentForSuggestions() {
        #expect(ChromiumPageRoute.isPrivateTypedText("chrome://exte"))
        #expect(ChromiumPageRoute.isPrivateTypedText("CHROME:"))
        #expect(ChromiumPageRoute.isPrivateTypedText("chrome-extension://abc"))
        #expect(ChromiumPageRoute.isPrivateTypedText("about:flags"))
        #expect(!ChromiumPageRoute.isPrivateTypedText("about:blank"))
        #expect(!ChromiumPageRoute.isPrivateTypedText("chromecast setup"))
        #expect(!ChromiumPageRoute.isPrivateTypedText("best chrome extensions"))
    }
}

@Suite struct BrowserURLResolverChromiumTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func webKitPanelsKeepSearchingInternalAddresses() {
        let resolver = BrowserURLResolver(homeDirectoryURL: home)
        #expect(resolver.navigableURL(from: "chrome://extensions") == nil)
        #expect(resolver.navigableURL(from: "about:flags") == nil)
        #expect(resolver.navigableURL(from: "chrome-extension://abc/popup.html") == nil)
    }

    @Test func chromiumPanelsLoadInternalAddressesInCanonicalForm() {
        let resolver = BrowserURLResolver(homeDirectoryURL: home, allowsChromiumSchemes: true)
        #expect(resolver.navigableURL(from: "chrome://extensions")?.absoluteString == "chrome://extensions/")
        #expect(resolver.navigableURL(from: "CHROME://Version")?.absoluteString == "chrome://version/")
        #expect(resolver.navigableURL(from: "about:flags")?.absoluteString == "chrome://flags/")
        #expect(resolver.navigableURL(from: "chrome-extension://abc/popup.html")?.absoluteString
            == "chrome-extension://abc/popup.html")
    }

    @Test func chromiumPanelsStillResolveWebAddressesAndSearches() {
        let resolver = BrowserURLResolver(homeDirectoryURL: home, allowsChromiumSchemes: true)
        #expect(resolver.navigableURL(from: "example.com")?.absoluteString == "https://example.com")
        #expect(resolver.navigableURL(from: "how do I use chrome") == nil)
        #expect(resolver.navigableURL(from: "javascript:alert(1)") == nil)
        #expect(resolver.navigableURL(from: "about:blank") == nil)
    }
}
