import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct URLResolutionTests {
    let resolver = BrowserURLResolver(homeDirectory: URL(filePath: "/Users/test", directoryHint: .isDirectory))

    private func resolved(_ input: String) -> String? {
        resolver.url(for: input)?.absoluteString
    }

    @Test func dottedHostsGetHTTPS() {
        #expect(resolved("example.com") == "https://example.com")
        #expect(resolved("  github.com/manaflow-ai/cmux  ") == "https://github.com/manaflow-ai/cmux")
        #expect(resolved("example.com:8080/path?q=1") == "https://example.com:8080/path?q=1")
        #expect(resolved("xn--bcher-kva.example") == "https://xn--bcher-kva.example")
    }

    @Test func loopbackHostsGetHTTP() {
        #expect(resolved("localhost") == "http://localhost")
        #expect(resolved("localhost:3000") == "http://localhost:3000")
        #expect(resolved("app.localhost:5173/x") == "http://app.localhost:5173/x")
        #expect(resolved("127.0.0.1:8080") == "http://127.0.0.1:8080")
        #expect(resolved("[::1]:3000") == "http://[::1]:3000")
        #expect(resolved("0.0.0.0:9000") == "http://0.0.0.0:9000")
    }

    @Test func lookalikeLoopbackHostsStayHTTPS() {
        #expect(resolved("localhost.evil.com") == "https://localhost.evil.com")
        #expect(resolved("127.0.0.1.evil.com") == "https://127.0.0.1.evil.com")
        #expect(resolved("10.0.0.5:8080") == "https://10.0.0.5:8080")
    }

    @Test func explicitSchemesArePreserved() {
        #expect(resolved("https://example.com/a?b=c#d") == "https://example.com/a?b=c#d")
        #expect(resolved("http://example.com") == "http://example.com")
        #expect(resolved("HTTPS://Example.com") == "HTTPS://Example.com")
        #expect(resolved("about:blank") == "about:blank")
        #expect(resolved("file:///tmp/x.html") == "file:///tmp/x.html")
    }

    @Test func dangerousAndForeignSchemesAreSearched() {
        #expect(resolved("javascript:alert(1)") == nil)
        #expect(resolved("data:text/html,hi") == nil)
        #expect(resolved("mailto:someone@example.com") == nil)
        #expect(resolved("ftp://example.com/file") == nil)
        #expect(resolved("about:config") == nil)
        #expect(resolved("http://") == nil)
    }

    @Test func textWithSpacesOrSingleWordsIsSearched() {
        #expect(resolved("hello world") == nil)
        #expect(resolved("what is 1.5 + 2") == nil)
        #expect(resolved("swift") == nil)
        #expect(resolved("node.js tutorial") == nil)
        #expect(resolved("") == nil)
        #expect(resolved("   ") == nil)
        #expect(resolved("1.5") == nil)
    }

    @Test func userInfoIsRefused() {
        #expect(resolved("user@evil.com") == nil)
        #expect(resolved("localhost:80@evil.example/path") == nil)
        #expect(resolved("127.0.0.1:80@evil.example") == nil)
    }

    @Test func pathsBecomeFileURLs() throws {
        let absolute = try #require(resolver.url(for: "/tmp/a b/c.html"))
        #expect(absolute.isFileURL)
        #expect(absolute.path(percentEncoded: false) == "/tmp/a b/c.html")

        let tilde = try #require(resolver.url(for: "~/Sites/index.html"))
        #expect(tilde.path(percentEncoded: false) == "/Users/test/Sites/index.html")

        let home = try #require(resolver.url(for: "~"))
        #expect(home.path(percentEncoded: false).hasPrefix("/Users/test"))
    }

    @Test func wrappedPasteIsJoinedOnlyAfterTheHost() {
        #expect(resolved("https://example.com/oauth/\ncallback?code=abc") == "https://example.com/oauth/callback?code=abc")
        #expect(resolved("example.com/very/long/\npath") == "https://example.com/very/long/path")
        #expect(resolved("example.\ncom/path") == nil)
        #expect(resolved("https://exam\nple.com/path") == nil)
        #expect(resolved("go\texample.com/path") == nil)
    }

    @Test func omniboxFallsBackToSearch() {
        let omnibox = OmniboxResolver(urlResolver: resolver, searchEngine: .duckDuckGo)
        #expect(omnibox.destination(for: "example.com") == .url(URL(string: "https://example.com")!))
        #expect(omnibox.destination(for: "a&b c+d") == .search(
            query: "a&b c+d",
            url: URL(string: "https://duckduckgo.com/?q=a%26b%20c%2Bd")!
        ))
        #expect(omnibox.destination(for: "  ") == nil)
    }

    @Test func searchEngineTemplates() {
        #expect(BrowserSearchEngine.google.searchURL(for: "cmux terminal")?.absoluteString
            == "https://www.google.com/search?q=cmux%20terminal")
        #expect(BrowserSearchEngine.google.searchURL(for: "日本") != nil)
        #expect(BrowserSearchEngine.google.searchURL(for: "") == nil)
        let broken = BrowserSearchEngine(id: "x", name: "X", queryTemplate: "https://x.example/search")
        #expect(broken.searchURL(for: "q") == nil)
    }

    @Test func displayTextIsCompact() {
        #expect(BrowserURLDisplay.displayText(for: URL(string: "https://www.example.com/")) == "example.com")
        #expect(BrowserURLDisplay.displayText(for: URL(string: "https://example.com/a%20b?x=1")) == "example.com/a b?x=1")
        #expect(BrowserURLDisplay.displayText(for: URL(string: "http://example.com")) == "http://example.com")
        #expect(BrowserURLDisplay.displayText(for: URL(string: "https://www.io/")) == "www.io")
        #expect(BrowserURLDisplay.displayText(for: URL(string: "https://user:pw@example.com/x")) == "example.com/x")
        #expect(BrowserURLDisplay.displayText(for: URL(filePath: "/tmp/a b.html")) == "/tmp/a b.html")
        #expect(BrowserURLDisplay.displayText(for: URL(string: "about:blank")) == "")
        #expect(BrowserURLDisplay.displayText(for: nil) == "")
        #expect(BrowserURLDisplay.editingText(for: URL(string: "https://example.com/")) == "https://example.com/")
    }
}
