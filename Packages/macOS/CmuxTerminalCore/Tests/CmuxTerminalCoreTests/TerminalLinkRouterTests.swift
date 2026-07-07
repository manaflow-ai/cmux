import Foundation
import Testing
import CmuxTerminalCore

/// A deterministic stand-in for the app normalizer, which accepts non-empty hosts.
private struct StubHostNormalizer: BrowserHostNormalizing {
    var rejectsEveryHost = false

    func normalizedHost(_ rawHost: String) -> String? {
        guard !rejectsEveryHost else { return nil }
        var trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            trimmed = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
        } else if let colon = trimmed.lastIndex(of: ":"),
                  trimmed[trimmed.index(after: colon)...].allSatisfy(\.isNumber),
                  trimmed.filter({ $0 == ":" }).count == 1 {
            trimmed = String(trimmed[..<colon])
        }
        let dotted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return dotted.isEmpty ? nil : dotted
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

    @Test func schemelessHostPathResolvesAsEmbeddedBrowser() throws {
        let target = try #require(router.resolveOpenURLTarget("example.com/docs"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected host-like schemeless path to route to embedded browser")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/docs")
    }

    @Test func schemelessLoopbackPathResolvesAsHTTPEmbeddedBrowser() throws {
        for (rawValue, expectedHost, expectedPort) in [
            ("localhost:3000/docs", "localhost", 3000),
            ("127.0.0.1:5173/docs", "127.0.0.1", 5173),
            ("deep.api.localhost/docs", "deep.api.localhost", nil),
        ] {
            let target = try #require(router.resolveOpenURLTarget(rawValue))
            guard case let .embeddedBrowser(url) = target else {
                Issue.record("Expected loopback schemeless path to route to embedded browser")
                return
            }
            #expect(url.scheme == "http")
            #expect(url.host == expectedHost)
            #expect(url.port == expectedPort)
            #expect(url.path == "/docs")
        }
    }

    @Test func wrappedPathFragmentDoesNotResolveAsHTTPSURL() {
        let target = router.resolveOpenURLTarget("s/pipeline-failure-state-model.md")
        #expect(target == nil)
    }

    @Test func unresolvedRelativePathDoesNotResolveAsHTTPSURL() {
        let target = router.resolveOpenURLTarget("README.md")
        #expect(target == nil)
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

    @Test func rejectedHostLeavesSchemelessTextUnresolved() {
        let rejecting = TerminalLinkRouter(hostNormalizer: StubHostNormalizer(rejectsEveryHost: true))
        #expect(rejecting.resolveOpenURLTarget("example.com/docs") == nil)
    }

    @Test func schemelessHostWithoutPathResolvesToNil() {
        #expect(router.resolveOpenURLTarget("example.com") == nil)
    }

    @Test func emptyTextResolvesToNil() {
        #expect(router.resolveOpenURLTarget("") == nil)
        #expect(router.resolveOpenURLTarget("   \n") == nil)
    }

    @Test func schemelessNonPathTokenResolvesToNil() {
        #expect(router.resolveOpenURLTarget("foo_bar") == nil)
    }

    @Test func openTargetURLAccessorReturnsDestination() throws {
        let embedded = try #require(router.resolveOpenURLTarget("https://example.com/a"))
        #expect(embedded.url.absoluteString == "https://example.com/a")
        let external = try #require(router.resolveOpenURLTarget("mailto:a@b.com"))
        #expect(external.url.absoluteString == "mailto:a@b.com")
    }
}
