import Foundation
import Testing
@testable import CmuxAuthRuntime

struct RedirectMethodPreservingDelegateTests {
    @Test(arguments: [
        ("relative/path", "other/path"),
        ("opaque:first", "opaque:second"),
        ("file:///tmp/source", "file:///tmp/target"),
        ("ws://example.test/source", "ws://example.test/target"),
        ("wss://example.test/source", "wss://example.test/target"),
        ("https://example.test/source", "https://other.test/target"),
        ("https://example.test/source", "http://example.test/target"),
        ("https://example.test/source", "https://example.test:8443/target"),
        ("https://example.test/source", "https://sub.example.test/target"),
    ])
    func nonHTTPOriginsFailClosed(
        source: String,
        target: String
    ) throws {
        let sourceURL = try #require(URL(string: source))
        let targetURL = try #require(URL(string: target))

        #expect(
            !RedirectMethodPreservingDelegate.sameOrigin(
                sourceURL,
                targetURL
            )
        )
    }

    @Test(arguments: [
        ("https://example.test/source", "https://example.test/target"),
        ("https://example.test:443/source", "https://example.test/target"),
        ("http://example.test:80/source", "http://EXAMPLE.test/target"),
    ])
    func canonicalHTTPOriginsMatch(
        source: String,
        target: String
    ) throws {
        let sourceURL = try #require(URL(string: source))
        let targetURL = try #require(URL(string: target))

        #expect(
            RedirectMethodPreservingDelegate.sameOrigin(
                sourceURL,
                targetURL
            )
        )
    }
}
