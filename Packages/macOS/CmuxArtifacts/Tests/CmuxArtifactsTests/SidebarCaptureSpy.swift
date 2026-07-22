import Foundation
@testable import CmuxArtifacts

actor SidebarCaptureSpy: ArtifactCapturing {
    private let rejectedSourceURLs: Set<URL>
    private(set) var addCallCount = 0
    private(set) var addedSourceURLs: [URL] = []
    private(set) var lastContext: ArtifactCaptureContext?

    init(rejectedSourceURLs: Set<URL> = []) {
        self.rejectedSourceURLs = rejectedSourceURLs
    }

    func capture(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) -> [ArtifactImportOutcome] {
        candidates.map { _ in .skipped(.automaticCaptureDisabled) }
    }

    func add(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) throws -> ArtifactImportOutcome {
        addCallCount += 1
        addedSourceURLs.append(sourceURL)
        lastContext = context
        if rejectedSourceURLs.contains(sourceURL) {
            throw ArtifactStoreError.unsupportedExtension(sourceURL.pathExtension)
        }
        return .alreadyStored(ArtifactRecord(
            digest: "digest",
            sourcePath: sourceURL.path,
            relativePath: sourceURL.lastPathComponent,
            workspaceID: context.workspaceID,
            sessionID: context.sessionID,
            provenance: .manual,
            capturedAt: capturedAt,
            size: 1
        ))
    }
}
