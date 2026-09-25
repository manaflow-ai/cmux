import Foundation
import Testing
import CmuxTerminalCore

/// A deterministic stand-in for the browser domain: hosts containing a dot or
/// equal to localhost are navigable, and scheme-less host-ish text becomes an
/// HTTPS URL the way the embedded browser's omnibox would treat it.
private struct StubHostNormalizer: BrowserHostNormalizing {
    var rejectsEveryHost = false

    func normalizedHost(_ rawHost: String) -> String? {
        guard !rejectsEveryHost else { return nil }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains(".") || trimmed == "localhost" else { return nil }
        return trimmed
    }

    func navigableWebURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if URL(string: trimmed)?.scheme != nil { return URL(string: trimmed) }
        guard trimmed.contains(".") || trimmed.lowercased().hasPrefix("localhost") else { return nil }
        return URL(string: "https://\(trimmed)")
    }
}

@Suite struct TerminalLinkRouterTests {
    private let router = TerminalLinkRouter(hostNormalizer: StubHostNormalizer())

    @Test func resolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try #require(router.resolveOpenURLTarget("https://example.com/path?q=1"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected web URL to route to embedded browser")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/path")
    }

    @Test func resolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try #require(router.resolveOpenURLTarget("example.com/docs"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected bare domain to be normalized as an HTTPS browser URL")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/docs")
    }

    @Test func resolvesFileSchemeAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("file:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected file URL to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux.txt")
    }

    @Test func resolvesAbsolutePathAsExternalFileURL() throws {
        let target = try #require(router.resolveOpenURLTarget("/tmp/cmux-path.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected absolute file path to open externally")
            return
        }
        #expect(url.isFileURL)
        #expect(url.path == "/tmp/cmux-path.txt")
    }

    @Test func resolvesNonWebSchemeAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("mailto:test@example.com"))
        guard case let .external(url) = target else {
            Issue.record("Expected non-web scheme to open externally")
            return
        }
        #expect(url.scheme == "mailto")
    }

    @Test func resolvesHostlessHTTPSAsExternal() throws {
        let target = try #require(router.resolveOpenURLTarget("https:///tmp/cmux.txt"))
        guard case let .external(url) = target else {
            Issue.record("Expected hostless HTTPS URL to open externally")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == nil)
        #expect(url.path == "/tmp/cmux.txt")
    }

    @Test func rejectedHostRoutesWebURLExternally() throws {
        let rejecting = TerminalLinkRouter(
            hostNormalizer: StubHostNormalizer(rejectsEveryHost: true)
        )
        let target = try #require(rejecting.resolveOpenURLTarget("https://example.com/path"))
        guard case let .external(url) = target else {
            Issue.record("Expected rejected host to fall back to external routing")
            return
        }
        #expect(url.host == "example.com")
    }

    @Test func rejectedHostRoutesBareDomainExternally() throws {
        let rejecting = TerminalLinkRouter(
            hostNormalizer: StubHostNormalizer(rejectsEveryHost: true)
        )
        // The rejecting stub also refuses navigableWebURL inputs only at the
        // host check, so build one that still yields a URL but fails the host
        // gate: navigableWebURL is unaffected by rejectsEveryHost.
        let target = rejecting.resolveOpenURLTarget("example.com/docs")
        guard case let .external(url)? = target else {
            Issue.record("Expected bare domain with rejected host to open externally")
            return
        }
        #expect(url.host == "example.com")
    }

    @Test func emptyTextResolvesToNil() {
        #expect(router.resolveOpenURLTarget("") == nil)
        #expect(router.resolveOpenURLTarget("   \n") == nil)
    }

    @Test func nonNavigableTokenFallsBackToExternalURL() {
        // Scheme-less text the browser cannot navigate still becomes an
        // external URL when Foundation can parse it as a relative URL.
        // (Multi-word text is deliberately not asserted here: URL(string:)
        // rejects spaces on macOS 14/15 but percent-encodes them on newer
        // Foundation, so its routing is OS-dependent.)
        let target = router.resolveOpenURLTarget("foo_bar")
        guard case let .external(url)? = target else {
            Issue.record("Expected non-navigable token to fall back to external routing")
            return
        }
        #expect(url.absoluteString == "foo_bar")
    }

    @Test func openTargetURLAccessorReturnsDestination() throws {
        let embedded = try #require(router.resolveOpenURLTarget("https://example.com/a"))
        #expect(embedded.url.absoluteString == "https://example.com/a")
        let external = try #require(router.resolveOpenURLTarget("mailto:a@b.com"))
        #expect(external.url.absoluteString == "mailto:a@b.com")
    }
}
