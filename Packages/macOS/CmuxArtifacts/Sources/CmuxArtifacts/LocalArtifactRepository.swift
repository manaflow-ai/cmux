import CmuxFoundation
import Foundation

/// Actor-backed durable catalog shared by all cmux workspaces in one process.
///
/// The JSON catalog is authoritative. File-backed payloads are copied below
/// ``ArtifactRepositoryPaths.payloads`` only after authorization, containment,
/// symlink, and size checks pass. Reads and searches never crawl terminal
/// scrollback or a user's home directory.
public actor LocalArtifactRepository: ArtifactStoring {
    /// Stable repository locations exposed for app adapters and tests.
    public nonisolated let paths: ArtifactRepositoryPaths
    /// Normalized resource policy used for all mutations and searches.
    public private(set) var configuration: ArtifactCaptureConfiguration

    // FileManager is documented thread-safe and is only accessed from this
    // actor; the explicit unsafe annotation is limited to this injected handle.
    nonisolated(unsafe) let fileManager: FileManager
    let now: @Sendable () -> Date
    let identity = ArtifactIdentity()
    let pathPolicy = ArtifactPathPolicy()
    /// Shared with terminal link capture so both apply one ignore-list contract.
    let hostPolicy = NetworkHostKeyPolicy()
    /// Upper bound on rows accepted from one catalog decode or snapshot import.
    ///
    /// This is a corruption and abuse guard, not a retention policy: the
    /// per-workspace retention limit runs after every load and import.
    static let maximumRestoredRecords = 100_000
    var recordsByIdentity: [String: ArtifactRecord] = [:]
    var loaded = false
    var loadFailure: ArtifactStoreError?
    var subscribers: [UUID: AsyncStream<ArtifactRepositoryChange>.Continuation] = [:]

    /// Creates a repository below an injected local directory.
    ///
    /// - Parameters:
    ///   - rootURL: Directory dedicated to the catalog; it is never treated as
    ///     a scan root for automatic capture.
    ///   - configuration: Resource and retention limits.
    ///   - fileManager: Filesystem seam used by tests and the app composition root.
    ///   - now: Clock seam used by retention tests.
    public init(
        rootURL: URL,
        configuration: ArtifactCaptureConfiguration = .defaultValue,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.paths = ArtifactRepositoryPaths(root: rootURL)
        self.configuration = configuration.normalized
        self.fileManager = fileManager
        self.now = now
    }

    /// Lists records in newest-first order, filtered before they leave the actor.
    public func list(scope: ArtifactScope) async throws -> [ArtifactRecord] {
        try ensureLoaded()
        try Task.checkCancellation()
        return ordered(recordsByIdentity.values.filter { matches($0, scope: scope) })
    }

    /// Looks up a stable record id without exposing the actor's backing map.
    public func record(id: UUID) async throws -> ArtifactRecord? {
        try ensureLoaded()
        try Task.checkCancellation()
        return recordsByIdentity.values.first { $0.id == id }
    }

    /// Searches the in-memory catalog with bounded cancellation checks.
    public func search(_ query: ArtifactSearchQuery) async throws -> [ArtifactSearchResult] {
        try ensureLoaded()
        try Task.checkCancellation()
        let records = ordered(recordsByIdentity.values)
        return try ArtifactSearchEngine().results(records: records, query: query)
    }

    /// Captures one explicitly authorized input and persists the reconciled row.
    public func ingest(
        _ request: ArtifactIngestRequest,
        capturedAt: Date = .now
    ) async throws -> ArtifactRecord {
        try ensureLoaded()
        try Task.checkCancellation()
        let policy = configuration
        if !policy.enabled,
           case .automatic = request.authorization {
            throw ArtifactStoreError.unsupportedKind("capture disabled")
        }
        // Normalize ownership before deriving the identity key. The key must
        // come from the same ownership that is stored on the row; otherwise
        // the next reload recomputes it with the derived project id and the
        // URL stops deduplicating against its persisted record.
        let request = normalizedRequest(request)
        let prepared = try prepare(request, capturedAt: capturedAt)
        if let existing = recordsByIdentity[prepared.identityKey] {
            let merged = existing.merging(
                source: request.source,
                lastSeenAt: capturedAt,
                title: request.title,
                metadata: prepared.metadata,
                userOwned: request.authorization == .explicitUser
            )
            recordsByIdentity[prepared.identityKey] = merged
            try enforceRetention(at: capturedAt)
            try persist()
            notify(.records([merged.id]))
            return merged
        }

        let record = ArtifactRecord(
            kind: prepared.kind,
            identityKey: prepared.identityKey,
            ownership: request.ownership,
            source: request.source,
            createdAt: capturedAt,
            lastSeenAt: capturedAt,
            occurrenceCount: 1,
            title: request.title,
            metadata: prepared.metadata,
            representation: prepared.representation,
            isUserOwned: request.authorization == .explicitUser
        )
        recordsByIdentity[record.identityKey] = record
        try enforceRetention(at: capturedAt)
        try persist()
        notify(.records([record.id]))
        return record
    }

    /// Reconciles a restored record without creating a duplicate identity.
    public func upsert(_ record: ArtifactRecord) async throws {
        try ensureLoaded()
        try Task.checkCancellation()
        let normalized = normalizedRecord(record)
        if let existing = recordsByIdentity[normalized.identityKey] {
            let merged = ArtifactRecord(
                id: existing.id,
                kind: existing.kind,
                identityKey: existing.identityKey,
                ownership: existing.ownership,
                source: normalized.lastSeenAt >= existing.lastSeenAt ? normalized.source : existing.source,
                createdAt: min(existing.createdAt, normalized.createdAt),
                lastSeenAt: max(existing.lastSeenAt, normalized.lastSeenAt),
                occurrenceCount: max(existing.occurrenceCount, normalized.occurrenceCount),
                title: normalized.title ?? existing.title,
                metadata: existing.metadata.merging(normalized.metadata) { current, _ in current },
                representation: existing.representation,
                isUserOwned: existing.isUserOwned || normalized.isUserOwned
            )
            recordsByIdentity[normalized.identityKey] = merged
            try enforceRetention(at: now())
            try persist()
            notify(.records([merged.id]))
            return
        }
        recordsByIdentity[normalized.identityKey] = normalized
        try enforceRetention(at: now())
        try persist()
        notify(.records([normalized.id]))
    }

    /// Replaces only records matching a scope; used to recover a dropped UI write event.
    public func replace(records: [ArtifactRecord], scope: ArtifactScope) async throws {
        try ensureLoaded()
        try Task.checkCancellation()
        var incoming: [String: ArtifactRecord] = [:]
        for record in records {
            let normalized = normalizedRecord(record)
            // A replacement is scoped by the caller's workspace/project. Do
            // not allow a malformed or stale projection to smuggle a record
            // owned by another scope into the global catalog.
            guard matches(normalized, scope: scope) else { continue }
            incoming[normalized.identityKey] = normalized
        }
        let keysToRemove = recordsByIdentity.compactMap { key, record in
            matches(record, scope: scope) && incoming[key] == nil ? key : nil
        }
        var removed: [ArtifactRecord] = []
        for key in keysToRemove {
            if let record = recordsByIdentity.removeValue(forKey: key) {
                removed.append(record)
            }
        }
        for record in incoming.values { recordsByIdentity[record.identityKey] = record }
        // Drop payload files only after the replacement rows are in place so
        // a payload the new projection still references survives.
        for record in removed {
            try removePayloadIfUnreferenced(record)
        }
        try enforceRetention(at: now())
        try persist()
        notify(.records(Set(incoming.values.map(\.id))))
    }

    /// Removes one row and any now-unreferenced managed payload.
    public func remove(id: UUID) async throws {
        try ensureLoaded()
        guard let pair = recordsByIdentity.first(where: { $0.value.id == id }) else {
            throw ArtifactStoreError.recordNotFound(id)
        }
        recordsByIdentity.removeValue(forKey: pair.key)
        try removePayloadIfUnreferenced(pair.value)
        try persist()
        notify(.records([id]))
    }

    /// Applies a live retention setting without rebuilding the catalog.
    public func updateRetentionLimit(_ limit: Int) async throws {
        try ensureLoaded()
        try Task.checkCancellation()
        configuration.retentionLimit = min(max(limit, 10), 10_000)
        try enforceRetention(at: now())
        try persist()
    }

    /// Clears records in one scope without affecting another workspace.
    public func clear(scope: ArtifactScope) async throws {
        try ensureLoaded()
        let removed = recordsByIdentity.filter { matches($0.value, scope: scope) }
        for (key, record) in removed {
            recordsByIdentity.removeValue(forKey: key)
            try removePayloadIfUnreferenced(record)
        }
        try persist()
        notify(.cleared(scope))
    }

    /// Imports old Links rows through the same URL identity and retention path.
    public func importLegacyLinks(
        _ links: [ArtifactLegacyLink],
        ownership: ArtifactOwnership
    ) async throws -> [ArtifactRecord] {
        try ensureLoaded()
        var imported: [ArtifactRecord] = []
        // `maximumBatchCount` bounds one producer burst. A snapshot upgrade is
        // a one-time import of the old per-workspace history (up to the Links
        // retention limit), so cap it by the catalog envelope instead and let
        // per-workspace retention decide what stays.
        for link in links.prefix(Self.maximumRestoredRecords) {
            try Task.checkCancellation()
            let rawURL = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedURL = URL(string: rawURL) else { continue }
            let canonical: String
            let kind: ArtifactKind
            if parsedURL.isFileURL {
                // Legacy Links rows are metadata references. Preserve an
                // already-captured file URL even when the current automatic
                // file-capture setting is disabled; that setting must not make
                // an upgrade silently erase history.
                canonical = parsedURL.standardizedFileURL.absoluteString
                kind = .file
            } else {
                guard let httpCanonical = identity.canonicalURL(rawURL) else { continue }
                canonical = httpCanonical
                kind = .url
            }
            let source: ArtifactSource = link.origin.lowercased() == "osc8" ? .terminalOSC8 : .terminalURL
            var metadata: [String: String] = [:]
            if let panelID = link.sourcePanelID { metadata["sourcePanelID"] = panelID.uuidString }
            if let surfaceTitle = link.sourceSurfaceTitle { metadata["sourceSurfaceTitle"] = surfaceTitle }
            let record = ArtifactRecord(
                id: link.id,
                kind: kind,
                identityKey: identity.key(kind: .url, value: canonical, ownership: normalizedOwnership(ownership)),
                ownership: normalizedOwnership(ownership),
                source: .migratedLink,
                createdAt: link.firstSeen,
                lastSeenAt: link.lastSeen,
                occurrenceCount: link.count,
                title: link.fetchedTitle,
                metadata: metadata,
                representation: .url(canonical)
            )
            if let existing = recordsByIdentity[record.identityKey] {
                let merged = existing.merging(
                    source: source,
                    lastSeenAt: record.lastSeenAt,
                    title: record.title,
                    metadata: record.metadata,
                    occurrenceIncrement: max(0, record.occurrenceCount - existing.occurrenceCount)
                )
                recordsByIdentity[record.identityKey] = merged
                imported.append(merged)
            } else {
                recordsByIdentity[record.identityKey] = record
                imported.append(record)
            }
        }
        try enforceRetention(at: now())
        try persist()
        notify(.records(Set(imported.map(\.id))))
        return imported
    }

    /// Returns a stream that finishes when its consumer cancels or the actor deallocates.
    public func changes() async -> AsyncStream<ArtifactRepositoryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ArtifactRepositoryChange>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        addSubscriber(id: id, continuation: continuation)
        return stream
    }

    /// Resolves a managed file or explicitly recorded directory after revalidation.
    public func materializedURL(for record: ArtifactRecord) async throws -> URL? {
        try ensureLoaded()
        try Task.checkCancellation()
        switch record.representation {
        case .url, .inlineText, .inlineHTML:
            return nil
        case .managedFile(let relativePath, _):
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw ArtifactStoreError.unauthorizedPath(relativePath)
            }
            let url = paths.payloads.appendingPathComponent(relativePath)
            guard paths.contains(url), isRegularFile(url), !isSymlink(url),
                  !pathPolicy.hasFinalSymlink(url) else {
                throw ArtifactStoreError.unauthorizedPath(url.path)
            }
            return url
        case .directory(let path):
            let url = pathPolicy.canonicalURL(URL(fileURLWithPath: path, isDirectory: true))
            guard fileManager.fileExists(atPath: url.path), !isSymlink(url) else {
                throw ArtifactStoreError.sourceUnavailable(path)
            }
            return url
        }
    }

    deinit {
        for continuation in subscribers.values { continuation.finish() }
    }
}
