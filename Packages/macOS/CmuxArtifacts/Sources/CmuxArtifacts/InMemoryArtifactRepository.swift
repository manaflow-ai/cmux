import Foundation

/// Deterministic repository used by unit tests and headless app composition.
public actor InMemoryArtifactRepository: ArtifactStoring {
    /// The same count/age policy used by the durable repository.
    public private(set) var configuration: ArtifactCaptureConfiguration
    private var recordsByIdentity: [String: ArtifactRecord] = [:]
    private var subscribers: [UUID: AsyncStream<ArtifactRepositoryChange>.Continuation] = [:]
    private let identity = ArtifactIdentity()

    /// Creates an empty in-memory catalog.
    public init(configuration: ArtifactCaptureConfiguration = .defaultValue) {
        self.configuration = configuration.normalized
    }

    /// Looks up a stable record id in the in-memory catalog.
    public func record(id: UUID) async throws -> ArtifactRecord? {
        try Task.checkCancellation()
        return recordsByIdentity.values.first { $0.id == id }
    }

    public func list(scope: ArtifactScope) async throws -> [ArtifactRecord] {
        try Task.checkCancellation()
        return ordered(recordsByIdentity.values.filter { matches($0, scope: scope) })
    }

    public func search(_ query: ArtifactSearchQuery) async throws -> [ArtifactSearchResult] {
        try Task.checkCancellation()
        return try ArtifactSearchEngine().results(records: ordered(recordsByIdentity.values), query: query)
    }

    public func ingest(_ request: ArtifactIngestRequest, capturedAt: Date) async throws -> ArtifactRecord {
        try Task.checkCancellation()
        let prepared: (ArtifactKind, String, ArtifactRepresentation) = try {
            switch request.input {
            case .url(let value):
                guard let canonical = identity.canonicalURL(value) else { throw ArtifactStoreError.unsupportedKind("url") }
                return (.url, identity.key(kind: .url, value: canonical, ownership: request.ownership), .url(canonical))
            case .html(let value):
                return (.html, identity.key(kind: .html, value: value), .inlineHTML(value))
            case .text(let value):
                let kind = request.kind ?? .text
                return (kind, identity.key(kind: kind, value: value), .inlineText(value))
            case .directory(let url):
                return (.directory, identity.key(kind: .directory, value: url.path), .directory(path: url.path))
            case .file, .data:
                throw ArtifactStoreError.unsupportedKind("file in in-memory repository")
            }
        }()
        if let existing = recordsByIdentity[prepared.1] {
            let merged = existing.merging(source: request.source, lastSeenAt: capturedAt, title: request.title, metadata: request.metadata)
            recordsByIdentity[prepared.1] = merged
            enforceRetention(at: capturedAt)
            notify(.records([merged.id]))
            return merged
        }
        let record = ArtifactRecord(
            kind: request.kind ?? prepared.0,
            identityKey: prepared.1,
            ownership: request.ownership,
            source: request.source,
            createdAt: capturedAt,
            lastSeenAt: capturedAt,
            title: request.title,
            metadata: request.metadata,
            representation: prepared.2,
            isUserOwned: request.authorization == .explicitUser
        )
        recordsByIdentity[record.identityKey] = record
        enforceRetention(at: capturedAt)
        notify(.records([record.id]))
        return record
    }

    public func upsert(_ record: ArtifactRecord) async throws {
        try Task.checkCancellation()
        recordsByIdentity[record.identityKey] = recordsByIdentity[record.identityKey].map { merge($0, record) } ?? record
        enforceRetention(at: .now)
        notify(.records([record.id]))
    }

    public func replace(records: [ArtifactRecord], scope: ArtifactScope) async throws {
        for (key, record) in recordsByIdentity where matches(record, scope: scope) && !records.contains(where: { $0.identityKey == key }) {
            recordsByIdentity.removeValue(forKey: key)
        }
        for record in records { recordsByIdentity[record.identityKey] = record }
        enforceRetention(at: .now)
        notify(.records(Set(records.map(\.id))))
    }

    public func remove(id: UUID) async throws {
        guard let key = recordsByIdentity.first(where: { $0.value.id == id })?.key else { throw ArtifactStoreError.recordNotFound(id) }
        recordsByIdentity.removeValue(forKey: key)
        notify(.records([id]))
    }

    /// Applies a live retention setting to the in-memory projection.
    public func updateRetentionLimit(_ limit: Int) async throws {
        configuration.retentionLimit = min(max(limit, 10), 10_000)
        enforceRetention(at: .now)
    }

    public func clear(scope: ArtifactScope) async throws {
        for (key, record) in recordsByIdentity where matches(record, scope: scope) { recordsByIdentity.removeValue(forKey: key) }
        notify(.cleared(scope))
    }

    public func importLegacyLinks(_ links: [ArtifactLegacyLink], ownership: ArtifactOwnership) async throws -> [ArtifactRecord] {
        var result: [ArtifactRecord] = []
        for link in links {
            let request = ArtifactIngestRequest(
                input: .url(link.url),
                ownership: ownership,
                source: .migratedLink,
                title: link.fetchedTitle,
                metadata: ["sourcePanelID": link.sourcePanelID?.uuidString ?? "", "sourceSurfaceTitle": link.sourceSurfaceTitle ?? ""]
            )
            let record = try await ingest(request, capturedAt: link.lastSeen)
            result.append(record)
        }
        return result
    }

    public func changes() async -> AsyncStream<ArtifactRepositoryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ArtifactRepositoryChange>.makeStream(bufferingPolicy: .bufferingNewest(32))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id: id) } }
        addSubscriber(id: id, continuation: continuation)
        return stream
    }

    public func materializedURL(for record: ArtifactRecord) async throws -> URL? {
        switch record.representation {
        case .directory(let path): return URL(fileURLWithPath: path, isDirectory: true)
        default: return nil
        }
    }

    private func matches(_ record: ArtifactRecord, scope: ArtifactScope) -> Bool {
        switch scope {
        case .global: true
        case .workspace(let id): record.ownership.workspaceID == id
        case .project(let id): record.ownership.projectID == id
        }
    }

    private func ordered<S: Sequence>(_ values: S) -> [ArtifactRecord] where S.Element == ArtifactRecord {
        values.sorted { $0.lastSeenAt == $1.lastSeenAt ? $0.id.uuidString < $1.id.uuidString : $0.lastSeenAt > $1.lastSeenAt }
    }

    private func merge(_ lhs: ArtifactRecord, _ rhs: ArtifactRecord) -> ArtifactRecord {
        ArtifactRecord(id: lhs.id, kind: lhs.kind, identityKey: lhs.identityKey, ownership: lhs.ownership, source: rhs.source, createdAt: min(lhs.createdAt, rhs.createdAt), lastSeenAt: max(lhs.lastSeenAt, rhs.lastSeenAt), occurrenceCount: max(lhs.occurrenceCount, rhs.occurrenceCount), title: rhs.title ?? lhs.title, metadata: lhs.metadata.merging(rhs.metadata) { current, _ in current }, representation: lhs.representation, isUserOwned: lhs.isUserOwned || rhs.isUserOwned)
    }

    private func notify(_ change: ArtifactRepositoryChange) {
        for continuation in subscribers.values { continuation.yield(change) }
    }

    private func addSubscriber(id: UUID, continuation: AsyncStream<ArtifactRepositoryChange>.Continuation) { subscribers[id] = continuation }
    private func removeSubscriber(id: UUID) { subscribers.removeValue(forKey: id) }

    private func enforceRetention(at date: Date) {
        let groups = Dictionary(grouping: recordsByIdentity.values) { $0.ownership.workspaceID ?? "<unowned>" }
        var retained = Set<String>()
        let cutoff = configuration.retentionAge > 0
            ? date.addingTimeInterval(-configuration.retentionAge)
            : nil
        for group in groups.values {
            let eligible = group.filter { record in
                guard let cutoff else { return true }
                return record.isUserOwned || record.lastSeenAt >= cutoff
            }.sorted {
                $0.lastSeenAt == $1.lastSeenAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.lastSeenAt > $1.lastSeenAt
            }
            let pinned = eligible.filter(\.isUserOwned)
            let automatic = eligible.filter { !$0.isUserOwned }
            retained.formUnion(pinned.map(\.identityKey))
            retained.formUnion(automatic.prefix(max(0, configuration.retentionLimit - pinned.count)).map(\.identityKey))
        }
        for key in recordsByIdentity.keys where !retained.contains(key) {
            recordsByIdentity.removeValue(forKey: key)
        }
    }
}
