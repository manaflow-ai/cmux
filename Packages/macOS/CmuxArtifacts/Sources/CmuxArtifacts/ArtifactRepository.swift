import Foundation

/// Change notifications emitted after a catalog mutation is durably attempted.
public enum ArtifactRepositoryChange: Equatable, Sendable {
    /// One or more records changed.
    case records(Set<UUID>)
    /// The catalog was cleared for a scope.
    case cleared(ArtifactScope)
}

/// The single persistence and mutation boundary for local artifacts.
public protocol ArtifactStoring: Sendable {
    /// Returns one record by its stable id, regardless of the active view scope.
    func record(id: UUID) async throws -> ArtifactRecord?
    /// Lists records in a stable newest-first order.
    func list(scope: ArtifactScope) async throws -> [ArtifactRecord]
    /// Searches the already-indexed catalog without scanning terminals.
    func search(_ query: ArtifactSearchQuery) async throws -> [ArtifactSearchResult]
    /// Captures one explicitly authorized input.
    func ingest(_ request: ArtifactIngestRequest, capturedAt: Date) async throws -> ArtifactRecord
    /// Inserts or reconciles a value restored from a workspace snapshot.
    func upsert(_ record: ArtifactRecord) async throws
    /// Replaces one workspace projection after a bounded queue overflow.
    func replace(records: [ArtifactRecord], scope: ArtifactScope) async throws
    /// Removes one record.
    func remove(id: UUID) async throws
    /// Changes the per-workspace retention cap and reconciles existing rows.
    func updateRetentionLimit(_ limit: Int) async throws
    /// Clears records in a scope.
    func clear(scope: ArtifactScope) async throws
    /// Migrates legacy Links rows without creating duplicate identities.
    func importLegacyLinks(
        _ links: [ArtifactLegacyLink],
        ownership: ArtifactOwnership
    ) async throws -> [ArtifactRecord]
    /// Installs and returns a cancellable stream of durable mutation notifications.
    ///
    /// The async boundary is intentional: registration happens on the actor
    /// before the caller can submit a mutation, so a freshly-created observer
    /// cannot miss its first event.
    func changes() async -> AsyncStream<ArtifactRepositoryChange>
    /// Resolves a file-backed record to a validated local URL for opening/dragging.
    func materializedURL(for record: ArtifactRecord) async throws -> URL?
}

/// Compatibility spelling retained for callers that used the upstream package.
public typealias ArtifactRepository = ArtifactStoring
