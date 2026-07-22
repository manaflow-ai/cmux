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
        sourceURLs: [URL],
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) -> [ArtifactImportAttempt] {
        addCallCount += 1
        addedSourceURLs.append(contentsOf: sourceURLs)
        lastContext = context
        return sourceURLs.map { sourceURL in
            if rejectedSourceURLs.contains(sourceURL) {
                return .rejected(.unsupportedExtension(sourceURL.pathExtension))
            }
            return .imported(.alreadyStored(ArtifactRecord(
                digest: "digest",
                sourcePath: sourceURL.path,
                relativePath: sourceURL.lastPathComponent,
                workspaceID: context.workspaceID,
                sessionID: context.sessionID,
                provenance: .manual,
                capturedAt: capturedAt,
                size: 1
            )))
        }
    }
}
