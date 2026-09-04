import Foundation

extension LocalArtifactRepository {
    func normalizedOwnership(_ ownership: ArtifactOwnership) -> ArtifactOwnership {
        if ownership.projectID != nil { return ownership }
        guard let root = ownership.projectRoot else { return ownership }
        return ArtifactOwnership(
            workspaceID: ownership.workspaceID,
            projectID: identity.stableTextDigest(root),
            projectRoot: pathPolicy.canonicalURL(URL(fileURLWithPath: root)).path,
            workspaceTitle: ownership.workspaceTitle
        )
    }

    func normalizedRecord(_ record: ArtifactRecord) -> ArtifactRecord {
        ArtifactRecord(
            id: record.id,
            kind: record.kind,
            identityKey: record.identityKey,
            ownership: normalizedOwnership(record.ownership),
            source: record.source,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt,
            occurrenceCount: record.occurrenceCount,
            title: record.title,
            metadata: record.metadata,
            representation: record.representation,
            isUserOwned: record.isUserOwned
        )
    }

    func merge(_ lhs: ArtifactRecord, _ rhs: ArtifactRecord) -> ArtifactRecord {
        ArtifactRecord(
            id: lhs.id,
            kind: lhs.kind,
            identityKey: lhs.identityKey,
            ownership: lhs.ownership,
            source: rhs.lastSeenAt >= lhs.lastSeenAt ? rhs.source : lhs.source,
            createdAt: min(lhs.createdAt, rhs.createdAt),
            lastSeenAt: max(lhs.lastSeenAt, rhs.lastSeenAt),
            occurrenceCount: max(lhs.occurrenceCount, rhs.occurrenceCount),
            title: rhs.title ?? lhs.title,
            metadata: lhs.metadata.merging(rhs.metadata) { current, _ in current },
            representation: lhs.representation,
            isUserOwned: lhs.isUserOwned || rhs.isUserOwned
        )
    }

    func ordered<S: Sequence>(_ records: S) -> [ArtifactRecord] where S.Element == ArtifactRecord {
        records.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func matches(_ record: ArtifactRecord, scope: ArtifactScope) -> Bool {
        switch scope {
        case .global: true
        case .workspace(let id): record.ownership.workspaceID == id
        case .project(let id): record.ownership.projectID == id
        }
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func notify(_ change: ArtifactRepositoryChange) {
        for continuation in subscribers.values { continuation.yield(change) }
    }

    func addSubscriber(
        id: UUID,
        continuation: AsyncStream<ArtifactRepositoryChange>.Continuation
    ) {
        subscribers[id] = continuation
    }

    func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

extension ArtifactRepresentation {
    var isManagedFile: Bool {
        if case .managedFile = self { return true }
        return false
    }

    var managedRelativePath: String? {
        guard case .managedFile(let relativePath, _) = self else { return nil }
        return relativePath
    }
}
