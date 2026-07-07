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

    func navigableWebURL(_ input: String) -> URL? {
        guard !rejectsEveryHost else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let lower = trimmed.lowercased()
        let bareHost = Self.bareHostCandidate(lower)
        if bareHost == "localhost" || bareHost == "127.0.0.1" ||
            bareHost == "0.0.0.0" || lower.hasPrefix("[::1]") ||
            (bareHost != ".localhost" && bareHost.hasSuffix(".localhost")) {
            return URL(string: "http://\(trimmed)")
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return url }
            if scheme == "file", url.isFileURL, url.path.hasPrefix("/") { return url }
            if Self.dottedHostWithPortCandidate(trimmed, schemeCandidate: scheme) {
                return URL(string: "https://\(trimmed)")
            }
            return nil
        }
        if trimmed.contains(":") || trimmed.contains("/") || trimmed.contains(".") {
            return URL(string: "https://\(trimmed)")
        }
        return nil
    }

    private static func bareHostCandidate(_ lowercasedInput: String) -> String {
        let end = lowercasedInput.firstIndex { character in
            character == ":" || character == "/" || character == "?" || character == "#"
        } ?? lowercasedInput.endIndex
        return String(lowercasedInput[..<end])
    }

    private static func dottedHostWithPortCandidate(_ input: String, schemeCandidate: String) -> Bool {
        guard schemeCandidate.contains(".") else { return false }
        guard input.count > schemeCandidate.count else { return false }
        let afterScheme = input.dropFirst(schemeCandidate.count)
        guard afterScheme.first == ":" else { return false }
        let portAndRest = afterScheme.dropFirst()
        let port = portAndRest.prefix(while: { $0.isNumber })
        guard !port.isEmpty, UInt16(port) != nil else { return false }
        let rest = portAndRest.dropFirst(port.count)
        return rest.isEmpty || rest.first == "/" || rest.first == "?" || rest.first == "#"
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

    @Test func resolvesExplicitFileLikeHTTPSHostAsEmbeddedBrowser() throws {
        let target = try #require(router.resolveOpenURLTarget("https://example.md:443"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected explicit HTTPS URL to route before file-line suppression")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.md")
        #expect(url.port == 443)
    }

    @Test func schemelessHostPathResolvesAsEmbeddedBrowser() throws {
        for (rawValue, expectedHost, expectedPath) in [
            ("example.com/docs", "example.com", "/docs"),
            ("0.0.0.0.evil.example/docs", "0.0.0.0.evil.example", "/docs"),
            ("grafana/dashboard", "grafana", "/dashboard"),
            ("grafana/dashboard.json", "grafana", "/dashboard.json"),
            ("s/dashboard.json", "s", "/dashboard.json"),
            ("x/app.js", "x", "/app.js"),
            ("wiki/docs/intro.md", "wiki", "/docs/intro.md"),
            ("gitlab/group/project/README.md", "gitlab", "/group/project/README.md"),
        ] {
            let target = try #require(router.resolveOpenURLTarget(rawValue))
            guard case let .embeddedBrowser(url) = target else {
                Issue.record("Expected host-like schemeless path to route to embedded browser")
                return
            }
            #expect(url.scheme == "https")
            #expect(url.host == expectedHost)
            #expect(url.path == expectedPath)
        }
    }

    @Test func schemelessDottedHostPortResolvesAsEmbeddedBrowser() throws {
        let target = try #require(router.resolveOpenURLTarget("example.com:8443"))
        guard case let .embeddedBrowser(url) = target else {
            Issue.record("Expected host:port schemeless token to route to embedded browser")
            return
        }
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.port == 8443)
    }

    @Test func schemelessLoopbackPathResolvesAsHTTPEmbeddedBrowser() throws {
        for (rawValue, expectedHost, expectedPort, expectedPath) in [
            ("localhost:3000", "localhost", 3000, ""),
            ("localhost:3000/docs", "localhost", 3000, "/docs"),
            ("127.0.0.1:5173/docs", "127.0.0.1", 5173, "/docs"),
            ("0.0.0.0:5173/docs", "0.0.0.0", 5173, "/docs"),
            ("deep.api.localhost/docs", "deep.api.localhost", nil, "/docs"),
        ] {
            let target = try #require(router.resolveOpenURLTarget(rawValue))
            guard case let .embeddedBrowser(url) = target else {
                Issue.record("Expected loopback schemeless path to route to embedded browser")
                return
            }
            #expect(url.scheme == "http")
            #expect(url.host == expectedHost)
            #expect(url.port == expectedPort)
            #expect(url.path == expectedPath)
        }
    }

    @Test func fileLineTokensDoNotResolveAsHostPorts() {
        #expect(router.resolveOpenURLTarget("README.md:12") == nil)
        #expect(router.resolveOpenURLTarget("README.md:443") == nil)
        #expect(router.resolveOpenURLTarget("App.swift:42") == nil)
        #expect(router.resolveOpenURLTarget("utils.py:42") == nil)
        #expect(router.resolveOpenURLTarget("lib.rs:10") == nil)
        #expect(router.resolveOpenURLTarget("main.swift:42") == nil)
        #expect(router.resolveOpenURLTarget("main.swift:443") == nil)
        #expect(router.resolveOpenURLTarget("index.ts:3000") == nil)
        #expect(router.resolveOpenURLTarget("server.go:8080") == nil)
        #expect(router.resolveOpenURLTarget("src/main.swift:3000") == nil)
        #expect(router.resolveOpenURLTarget("Sources/App.swift:8080") == nil)
        #expect(router.resolveOpenURLTarget("App.swift:42:17") == nil)
        #expect(router.resolveOpenURLTarget("Sources/App.swift:42:17") == nil)
    }

    @Test func fileLikeTLDHostPortsResolveAsEmbeddedBrowser() throws {
        for (rawValue, expectedHost, expectedPort) in [
            ("docs.rs:443", "docs.rs", 443),
            ("bun.sh:443", "bun.sh", 443),
            ("example.md:443", "example.md", 443),
            ("docs.md:8123", "docs.md", 8123),
        ] {
            let target = try #require(router.resolveOpenURLTarget(rawValue))
            guard case let .embeddedBrowser(url) = target else {
                Issue.record("Expected file-like TLD host:port to route through browser normalization")
                return
            }
            #expect(url.scheme == "https")
            #expect(url.host == expectedHost)
            #expect(url.port == expectedPort)
        }
    }

    @Test func wrappedPathFragmentDoesNotResolveAsHTTPSURL() {
        let target = router.resolveOpenURLTarget("s/pipeline-failure-state-model.md")
        #expect(target == nil)
    }

    @Test func unresolvedRelativePathDoesNotResolveAsHTTPSURL() {
        #expect(router.resolveOpenURLTarget("foo_bar") == nil)
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

    @Test func schemelessHostWithoutPathResolvesAsEmbeddedBrowser() throws {
        for (rawValue, expectedHost, expectedScheme) in [
            ("example.com", "example.com", "https"),
            ("example.com?x=1", "example.com", "https"),
            ("bun.sh", "bun.sh", "https"),
            ("docs.rs", "docs.rs", "https"),
            ("example.md", "example.md", "https"),
            ("localhost", "localhost", "http"),
        ] {
            let target = try #require(router.resolveOpenURLTarget(rawValue))
            guard case let .embeddedBrowser(url) = target else {
                Issue.record("Expected browser-navigable host to route to embedded browser")
                return
            }
            #expect(url.scheme == expectedScheme)
            #expect(url.host == expectedHost)
        }
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
