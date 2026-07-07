import Foundation
import Testing
import CmuxTerminalCore

/// A deterministic stand-in for the browser domain: hosts containing a dot or
/// equal to localhost are accepted for explicit web URLs.
private struct StubHostNormalizer: BrowserHostNormalizing {
    var rejectsEveryHost = false

    func normalizedHost(_ rawHost: String) -> String? {
        guard !rejectsEveryHost else { return nil }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.contains(".") || trimmed == "localhost" else { return nil }
        return trimmed
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

    @Test func schemelessBareDomainResolvesToNil() {
        #expect(router.resolveOpenURLTarget("example.com/docs") == nil)
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

    @Test func rejectedHostDoesNotAffectSchemelessText() {
        let rejecting = TerminalLinkRouter(hostNormalizer: StubHostNormalizer(rejectsEveryHost: true))
        #expect(rejecting.resolveOpenURLTarget("example.com/docs") == nil)
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
