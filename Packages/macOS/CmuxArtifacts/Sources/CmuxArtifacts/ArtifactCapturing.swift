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

    /// Explicitly adds one regular file through the validated capture path.
    ///
    /// - Parameters:
    ///   - sourceURL: Existing regular file to add.
    ///   - context: Project and workspace grouping identity.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: Copy, deduplication, or already-stored result.
    func add(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        capturedAt: Date
    ) async throws -> ArtifactImportOutcome
}
