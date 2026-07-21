import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact search engine")
struct ArtifactSearchEngineTests {
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
