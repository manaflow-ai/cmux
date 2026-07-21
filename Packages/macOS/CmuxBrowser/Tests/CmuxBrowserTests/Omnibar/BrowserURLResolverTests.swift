import Testing

@testable import CmuxBrowser

@Suite struct BrowserURLResolverTests {
    private let resolver = BrowserURLResolver()

    @Test func resolvesWrappedOAuthURLWithoutRewriting() throws {
        let expected =
            "https://auth.openai.com/oauth/authorize?client_id=app_123" +
            "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcallback" +
            "&scope=openid%20profile&state=abc123"
        let wrapped = expected.replacingOccurrences(of: "&scope=", with: "&\nscope=")

        #expect(try #require(resolver.navigableURL(from: wrapped)).absoluteString == expected)
    }

    @Test func resolvesSingleLineFieldRepresentationWithoutSearching() throws {
        let expected = "https://example.com/callback?scope=openid%20profile&state=abc123"
        let fieldValue = expected.replacingOccurrences(of: "&state=", with: "& state=")

        #expect(try #require(resolver.navigableURL(from: fieldValue)).absoluteString == expected)
    }

    @Test func preservesExistingNavigationAndSearchBoundaries() throws {
        #expect(try #require(resolver.navigableURL(from: "localhost:3000")).absoluteString == "http://localhost:3000")
        #expect(
            try #require(resolver.navigableURL(from: "example.com/path?x=1")).absoluteString ==
                "https://example.com/path?x=1"
        )
        #expect(resolver.navigableURL(from: "node.js tutorial") == nil)
        #expect(resolver.navigableURL(from: "node.js\ttutorial") == nil)
    }

    @Test func preservesSupportedAndRejectedSchemes() throws {
        #expect(try #require(resolver.navigableURL(from: "file:///tmp/example.html")).isFileURL)
        #expect(resolver.navigableURL(from: "mailto:test@example.com") == nil)
        #expect(resolver.navigableURL(from: "ftp://example.com/file.html") == nil)
    }
}
