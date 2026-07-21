import Foundation
@testable import CmuxArtifacts

actor SidebarCaptureSpy: ArtifactCapturing {
    private(set) var lastAdd: SidebarCaptureAddCall?

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
        lastAdd = SidebarCaptureAddCall(sourceURL: sourceURL, context: context)
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
