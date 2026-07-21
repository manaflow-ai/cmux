import Foundation
@testable import CmuxArtifacts

actor SidebarArtifactStore: ArtifactStoring {
    let root: URL
    private var nodes: [ArtifactNode]
    private var searchResults: [ArtifactSearchResult] = []
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private(set) var lastQuery: String?

    init(root: URL, nodes: [ArtifactNode]) {
        self.root = root.standardizedFileURL
        self.nodes = nodes
    }

    func setSearchResults(_ results: [ArtifactSearchResult]) {
        searchResults = results
    }

    func replaceNodes(_ nodes: [ArtifactNode], notify: Bool) {
        self.nodes = nodes
        if notify { continuations.forEach { $0.yield(()) } }
    }

    func locateProjectRoot(startingAt: URL) -> URL { root }
    func configuration(projectRoot: URL) -> ArtifactCaptureConfiguration { .defaultValue }
    func snapshot(projectRoot: URL) -> ArtifactSnapshot {
        ArtifactSnapshot(
            projectRoot: root,
            artifactsRoot: root.appendingPathComponent(".cmux/artifacts", isDirectory: true),
            nodes: nodes,
            isTruncated: false
        )
    }

    func search(projectRoot: URL, query: String) -> [ArtifactSearchResult] {
        lastQuery = query
        return searchResults
    }

    func importFile(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) throws -> ArtifactImportOutcome {
        throw ArtifactStoreError.sourceNotRegularFile(sourceURL.path)
    }

    func resolve(projectRoot: URL, name: String) throws -> ArtifactNode {
        throw ArtifactStoreError.artifactNotFound(name)
    }

    func changes(projectRoot: URL) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream()
        continuations.append(pair.continuation)
        pair.continuation.yield(())
        return pair.stream
    }
}
