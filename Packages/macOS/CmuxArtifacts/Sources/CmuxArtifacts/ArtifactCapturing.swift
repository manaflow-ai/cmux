public import Foundation

/// Validated capture seam shared by automatic capture and manual UI entrypoints.
public protocol ArtifactCapturing: Sendable {
    /// Captures eligible detector candidates using project policy.
    ///
    /// - Parameters:
    ///   - candidates: Paths emitted by an artifact detector.
    ///   - context: Project, workspace, and session grouping identity.
    ///   - capturedAt: Timestamp recorded for accepted paths.
    /// - Returns: One result for each distinct candidate.
    func capture(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) async -> [ArtifactImportOutcome]

    /// Explicitly adds regular files through the validated capture path.
    ///
    /// - Parameters:
    ///   - sourceURLs: Existing regular files to add.
    ///   - context: Project and workspace grouping identity.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: One import attempt per source URL, preserving input order.
    func add(
        sourceURLs: [URL],
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) async -> [ArtifactImportAttempt]
}

public extension ArtifactCapturing {
    /// Explicitly adds one regular file through the validated capture path.
    ///
    /// - Parameters:
    ///   - sourceURL: Existing regular file to add.
    ///   - context: Project and workspace grouping identity.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: Copy, deduplication, or already-stored result.
    /// - Throws: ``ArtifactStoreError`` when repository validation rejects the file.
    func add(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        capturedAt: Date = .now
    ) async throws -> ArtifactImportOutcome {
        guard let attempt = await add(
            sourceURLs: [sourceURL],
            context: context,
            capturedAt: capturedAt
        ).first else {
            throw ArtifactStoreError.sourceNotRegularFile(sourceURL.path)
        }
        switch attempt {
        case .imported(let outcome):
            return outcome
        case .rejected(let error):
            throw error
        }
    }
}
