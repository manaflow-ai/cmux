public import Foundation

/// Filesystem persistence seam shared by the app, capture service, and CLI.
public protocol ArtifactStoring: Sendable {
    /// Resolves the project root that should own artifacts for a working path.
    func locateProjectRoot(startingAt: URL) async -> URL
    /// Loads project capture configuration.
    func configuration(projectRoot: URL) async -> ArtifactCaptureConfiguration
    /// Scans the live artifact filesystem into immutable values.
    func snapshot(projectRoot: URL) async throws -> ArtifactSnapshot
    /// Searches filenames and bounded text contents.
    func search(projectRoot: URL, query: String) async throws -> [ArtifactSearchResult]
    /// Imports or deduplicates one accepted regular file.
    func importFile(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        provenance: ArtifactProvenance,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) async throws -> ArtifactImportOutcome
    /// Imports one homogeneous candidate batch with shared filesystem work.
    ///
    /// - Parameters:
    ///   - candidates: Ordered source files and their provenance.
    ///   - context: Project and session destination identity.
    ///   - configuration: Per-file persistence and safety limits.
    ///   - maximumBatchBytes: Optional aggregate staging limit; `nil` permits every per-file-valid source.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: One import attempt per candidate, preserving input order.
    func importFiles(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration,
        maximumBatchBytes: Int64?,
        capturedAt: Date
    ) async -> [ArtifactImportAttempt]
    /// Resolves an exact relative path, unique basename, or unique fuzzy filename.
    func resolve(projectRoot: URL, name: String) async throws -> ArtifactNode
    /// Installs observation immediately and emits subsequent recursive `.cmux` filesystem changes.
    func changes(projectRoot: URL) async -> AsyncStream<Void>
}

extension ArtifactStoring {
    /// Default batch behavior for injected stores that only implement single-file import.
    public func importFiles(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration,
        maximumBatchBytes: Int64?,
        capturedAt: Date
    ) async -> [ArtifactImportAttempt] {
        var attempts: [ArtifactImportAttempt] = []
        attempts.reserveCapacity(candidates.count)
        for candidate in candidates {
            do {
                attempts.append(.imported(try await importFile(
                    sourceURL: candidate.sourceURL,
                    context: context,
                    provenance: candidate.provenance,
                    configuration: configuration,
                    capturedAt: capturedAt
                )))
            } catch let error as ArtifactStoreError {
                attempts.append(.rejected(error))
            } catch {
                attempts.append(.rejected(.sourceNotRegularFile(candidate.sourceURL.path)))
            }
        }
        return attempts
    }
}
