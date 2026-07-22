import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact search engine")
struct ArtifactSearchEngineTests {
    @Test("Content search rejects a file that grew beyond its stale snapshot size")
    func rejectsFileGrowthAfterSnapshot() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let url = try ArtifactTestSupport.write("x", named: "artifact.txt", under: root)
        let staleNode = node(url: url)
        try "needle".write(to: url, atomically: true, encoding: .utf8)
        let snapshot = ArtifactSnapshot(
            projectRoot: root,
            artifactsRoot: root,
            nodes: [staleNode],
            isTruncated: false
        )
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.contentSearchMaximumBytes = 2
        configuration.contentSearchTotalMaximumBytes = 2

        let results = try ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: "needle"
        )

        #expect(results.isEmpty)
    }

    @Test("Content search does not follow a symlink outside the artifact store")
    func rejectsSymlinkReplacement() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let store = root.appendingPathComponent("store", isDirectory: true)
        let outside = try ArtifactTestSupport.write("needle", named: "outside.txt", under: root)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let link = store.appendingPathComponent("artifact.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkedNode = ArtifactNode(
            id: "artifact.txt",
            name: "artifact.txt",
            relativePath: "artifact.txt",
            absolutePath: link.path,
            isDirectory: false,
            fileKind: .text,
            size: Int64("needle".utf8.count),
            modifiedAt: nil,
            children: []
        )
        let snapshot = ArtifactSnapshot(
            projectRoot: root,
            artifactsRoot: store,
            nodes: [linkedNode],
            isTruncated: false
        )

        let results = try ArtifactSearchEngine(configuration: .defaultValue).results(
            snapshot: snapshot,
            query: "needle"
        )

        #expect(results.isEmpty)
    }

    @Test("Content search enforces its aggregate byte budget")
    func enforcesAggregateContentBudget() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let firstURL = try ArtifactTestSupport.write("haystack", named: "a.txt", under: root)
        let secondURL = try ArtifactTestSupport.write("needle", named: "b.txt", under: root)
        let nodes = [node(url: firstURL), node(url: secondURL)]
        let snapshot = ArtifactSnapshot(
            projectRoot: root,
            artifactsRoot: root,
            nodes: nodes,
            isTruncated: false
        )
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.contentSearchTotalMaximumBytes = Int64("haystack".utf8.count)

        let capped = try ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: "needle"
        )

        #expect(capped.isEmpty)
        configuration.contentSearchTotalMaximumBytes += Int64("needle".utf8.count)
        let uncapped = try ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: "needle"
        )
        #expect(uncapped.map(\.node.name) == ["b.txt"])
        #expect(uncapped.first?.matchedContent == true)
    }

    @Test("Oversized queries use one bounded prefix for every candidate")
    func boundsQueryBeforeScoring() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let query = String(repeating: "a", count: 4_096)
        let node = ArtifactNode(
            id: "large-name",
            name: query + ".png",
            relativePath: query + ".png",
            absolutePath: root.appendingPathComponent("large-name.png").path,
            isDirectory: false,
            fileKind: .image,
            size: 1,
            modifiedAt: nil,
            children: []
        )
        let snapshot = ArtifactSnapshot(
            projectRoot: root,
            artifactsRoot: root,
            nodes: [node],
            isTruncated: false
        )
        let engine = ArtifactSearchEngine(configuration: .defaultValue)

        let oversizedScore = try #require(engine.results(snapshot: snapshot, query: query).first?.score)
        let boundedScore = try #require(
            engine.results(snapshot: snapshot, query: String(query.prefix(512))).first?.score
        )

        #expect(oversizedScore == boundedScore)
    }

    private func node(url: URL) -> ArtifactNode {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return ArtifactNode(
            id: url.lastPathComponent,
            name: url.lastPathComponent,
            relativePath: url.lastPathComponent,
            absolutePath: url.path,
            isDirectory: false,
            fileKind: .text,
            size: size,
            modifiedAt: nil,
            children: []
        )
    }
}
