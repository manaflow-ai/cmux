import Foundation
@testable import CmuxArtifacts

actor ConfiguredArtifactStore: ArtifactStoring {
    let fixedConfiguration: ArtifactCaptureConfiguration
    private(set) var importCount = 0
    private(set) var batchImportCount = 0
    private(set) var configurationReadCount = 0

    init(configuration: ArtifactCaptureConfiguration) {
        fixedConfiguration = configuration
    }

    func locateProjectRoot(startingAt: URL) -> URL { startingAt }

    func configuration(projectRoot: URL) -> ArtifactCaptureConfiguration {
        configurationReadCount += 1
        return fixedConfiguration
    }

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

    func importFiles(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) -> [ArtifactImportAttempt] {
        batchImportCount += 1
        return candidates.map { candidate in
            do {
                return .imported(try importFile(
                    sourceURL: candidate.sourceURL,
                    context: context,
                    provenance: candidate.provenance,
                    configuration: configuration,
                    capturedAt: capturedAt
                ))
            } catch let error as ArtifactStoreError {
                return .rejected(error)
            } catch {
                return .rejected(.sourceNotRegularFile(candidate.sourceURL.path))
            }
        }
    }

    func resolve(projectRoot: URL, name: String) throws -> ArtifactNode {
        throw ArtifactStoreError.artifactNotFound(name)
    }

    func changes(projectRoot: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
