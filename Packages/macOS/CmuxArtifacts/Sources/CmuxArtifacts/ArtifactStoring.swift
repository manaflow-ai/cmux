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
    /// Resolves an exact relative path, unique basename, or unique fuzzy filename.
    func resolve(projectRoot: URL, name: String) async throws -> ArtifactNode
    /// Emits recursive filesystem changes for one project's artifact root.
    func changes(projectRoot: URL) async -> AsyncStream<Void>
}
