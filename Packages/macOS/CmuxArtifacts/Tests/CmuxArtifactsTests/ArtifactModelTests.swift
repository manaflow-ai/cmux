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
}
