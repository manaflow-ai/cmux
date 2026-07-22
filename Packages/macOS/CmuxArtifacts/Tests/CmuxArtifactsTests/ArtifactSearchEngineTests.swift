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

        let results = ArtifactSearchEngine(configuration: configuration).results(
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

        let results = ArtifactSearchEngine(configuration: .defaultValue).results(
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

        let capped = ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: "needle"
        )

        #expect(capped.isEmpty)
        configuration.contentSearchTotalMaximumBytes += Int64("needle".utf8.count)
        let uncapped = ArtifactSearchEngine(configuration: configuration).results(
            snapshot: snapshot,
            query: "needle"
        )
        #expect(uncapped.map(\.node.name) == ["b.txt"])
        #expect(uncapped.first?.matchedContent == true)
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
