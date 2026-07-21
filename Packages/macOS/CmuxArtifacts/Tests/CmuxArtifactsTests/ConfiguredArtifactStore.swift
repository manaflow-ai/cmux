import Foundation
@testable import CmuxArtifacts

actor ConfiguredArtifactStore: ArtifactStoring {
    let fixedConfiguration: ArtifactCaptureConfiguration
    private(set) var importCount = 0

    init(configuration: ArtifactCaptureConfiguration) {
        fixedConfiguration = configuration
    }

    func locateProjectRoot(startingAt: URL) -> URL { startingAt }

    func configuration(projectRoot: URL) -> ArtifactCaptureConfiguration { fixedConfiguration }

    func snapshot(projectRoot: URL) throws -> ArtifactSnapshot {
        ArtifactSnapshot(projectRoot: projectRoot, artifactsRoot: projectRoot, nodes: [], isTruncated: false)
    }

    func search(projectRoot: URL, query: String) -> [ArtifactSearchResult] { [] }

    func importFile(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) throws -> ArtifactImportOutcome {
        importCount += 1
        return .alreadyStored(ArtifactRecord(
            digest: sourceURL.lastPathComponent,
            sourcePath: sourceURL.path,
            relativePath: sourceURL.lastPathComponent,
            workspaceID: context.workspaceID,
            sessionID: context.sessionID,
            provenance: provenance,
            capturedAt: capturedAt,
            size: 0
        ))
    }

    func resolve(projectRoot: URL, name: String) throws -> ArtifactNode {
        throw ArtifactStoreError.artifactNotFound(name)
    }

    func changes(projectRoot: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
