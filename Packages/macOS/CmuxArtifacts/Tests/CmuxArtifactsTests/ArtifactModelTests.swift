import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact model")
struct ArtifactModelTests {
    @Test("URL identity canonicalizes host, default port, and trailing dot")
    func canonicalURLIdentity() throws {
        let identity = ArtifactIdentity()
        let first = try #require(identity.canonicalURL("HTTPS://Example.COM.:443/a"))
        let second = try #require(identity.canonicalURL("https://example.com/a"))
        #expect(first == second)
        #expect(identity.key(kind: .url, value: first) == identity.key(kind: .url, value: second))
    }

    @Test("URL identity keeps IPv6 literals bracketed")
    func canonicalURLKeepsIPv6Brackets() {
        let identity = ArtifactIdentity()
        #expect(identity.canonicalURL("HTTP://[::1]:8080/x") == "http://[::1]:8080/x")
        #expect(identity.canonicalURL("http://[fe80::1]/") == "http://[fe80::1]/")
        #expect(identity.canonicalURL("https://[2001:DB8::1]:443/a") == "https://[2001:db8::1]/a")
        #expect(identity.key(kind: .url, value: "http://[::1]:8080/x") == identity.key(kind: .url, value: "HTTP://[::1]:8080/x"))
    }

    @Test("search covers title, metadata, and inline content")
    func searchCoversMetadata() throws {
        let owner = ArtifactOwnership(workspaceID: "w1", projectRoot: "/tmp/project")
        let record = ArtifactRecord(
            kind: .json,
            identityKey: "json:one",
            ownership: owner,
            source: .manual,
            title: "Build manifest",
            metadata: ["sourceSurfaceTitle": "CI"],
            representation: .inlineText("artifact-token: 42")
        )
        let engine = ArtifactSearchEngine()
        #expect(try engine.results(records: [record], query: .init(text: "manifest", scope: .global)).first?.record.id == record.id)
        #expect(try engine.results(records: [record], query: .init(text: "artifact-token", scope: .global)).first?.snippet == "artifact-token: 42")
        #expect(try engine.results(records: [record], query: .init(text: "CI", scope: .workspace("other"))).isEmpty)
    }

    @Test("path policy rejects sensitive and escaping automatic paths")
    func pathPolicy() {
        let policy = ArtifactPathPolicy()
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        #expect(policy.isContained(URL(fileURLWithPath: "/tmp/project/src/a.txt"), in: [root]))
        #expect(!policy.isContained(URL(fileURLWithPath: "/tmp/project-other/a.txt"), in: [root]))
        #expect(policy.isSensitive(URL(fileURLWithPath: "/Users/test/.ssh/id_ed25519")))
    }

    @Test("unknown future kinds survive Codable round trips")
    func unknownKindRoundTrip() throws {
        let kind = ArtifactKind(rawValue: "future-canvas")
        #expect(kind == .unknown("future-canvas"))
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(ArtifactKind.self, from: data)
        #expect(decoded == kind)
    }

    @Test("kind, source, and host filters share the search contract")
    func searchFilters() throws {
        let owner = ArtifactOwnership(workspaceID: "w")
        let url = ArtifactRecord(
            kind: .url,
            identityKey: "url:one",
            ownership: owner,
            source: .terminalURL,
            metadata: ["host": "example.com"],
            representation: .url("https://example.com/a")
        )
        let html = ArtifactRecord(
            kind: .html,
            identityKey: "html:one",
            ownership: owner,
            source: .browser,
            representation: .inlineHTML("<p>hello</p>")
        )
        let engine = ArtifactSearchEngine()
        let result = try engine.results(
            records: [url, html],
            query: .init(kindGroup: .links, source: .terminalURL, host: "example.com")
        )
        #expect(result.map(\.record.id) == [url.id])
    }

    @Test("capture configuration decodes older documents with new limits absent")
    func captureConfigurationBackwardsDecode() throws {
        let data = Data(#"{"enabled":true,"retentionLimit":42}"#.utf8)
        let decoded = try JSONDecoder().decode(ArtifactCaptureConfiguration.self, from: data)
        #expect(decoded.retentionLimit == 42)
        #expect(decoded.maximumIndexedContentBytes == 64 * 1024)
        #expect(decoded.maximumCatalogBytes == 16 * 1024 * 1024)
    }
}
