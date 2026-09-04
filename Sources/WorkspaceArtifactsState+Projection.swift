import CmuxArtifacts
import Foundation

/// Projection and legacy-Link compatibility operations for the workspace
/// Artifacts model. Keeping these operations in an extension keeps the state
/// owner small while preserving one mutation path.
extension WorkspaceArtifactsState {
    var ownership: ArtifactOwnership {
        let projectRoot = workingDirectory.map(identity.canonicalPath)
        ArtifactOwnership(
            workspaceID: workspaceID?.uuidString,
            projectID: projectRoot.map(identity.stableTextDigest),
            projectRoot: projectRoot,
            workspaceTitle: nil
        )
    }

    func merge(_ incoming: ArtifactRecord, at date: Date) -> ArtifactRecord {
        if let existing = recordsByIdentity[incoming.identityKey] {
            let updated = existing.merging(source: incoming.source, lastSeenAt: date, title: incoming.title, metadata: incoming.metadata)
            recordsByIdentity[incoming.identityKey] = updated
            records = ordered(recordsByIdentity.values)
            return updated
        }
        recordsByIdentity[incoming.identityKey] = incoming
        nextOrder &+= 1
        orderByID[incoming.id] = nextOrder
        records = ordered(recordsByIdentity.values)
        if records.count > retentionLimit, let oldest = records.last {
            recordsByIdentity.removeValue(forKey: oldest.identityKey)
            orderByID.removeValue(forKey: oldest.id)
            titleStateByID.removeValue(forKey: oldest.id)
            titleGenerationByID.removeValue(forKey: oldest.id)
            activeTitleFetchIDByID.removeValue(forKey: oldest.id)
            titleRetryAfterByID.removeValue(forKey: oldest.id)
            records.removeLast()
        }
        return incoming
    }

    func captureInMemory(_ request: ArtifactIngestRequest, capturedAt: Date) -> ArtifactRecord? {
        let representation: ArtifactRepresentation
        let kind: ArtifactKind
        let identityValue: String
        switch request.input {
        case .url(let value):
            guard let canonical = identity.canonicalURL(value) else { return nil }
            representation = .url(canonical); kind = request.kind ?? .url; identityValue = canonical
        case .html(let value): representation = .inlineHTML(value); kind = request.kind ?? .html; identityValue = value
        case .text(let value): representation = .inlineText(value); kind = request.kind ?? .text; identityValue = value
        case .directory(let url): representation = .directory(path: url.path); kind = .directory; identityValue = url.path
        case .file, .data: return nil
        }
        let record = ArtifactRecord(
            kind: kind,
            identityKey: identity.key(kind: kind == .url ? .url : kind, value: identityValue, ownership: ownership),
            ownership: ownership,
            source: request.source,
            createdAt: capturedAt,
            lastSeenAt: capturedAt,
            title: request.title,
            metadata: request.metadata,
            representation: representation,
            isUserOwned: request.authorization == .explicitUser
        )
        let merged = merge(record, at: capturedAt)
        markStructuralChange()
        return merged
    }

    func upsertProjection(_ record: ArtifactRecord) {
        if let existing = recordsByIdentity[record.identityKey], existing.id != record.id {
            recordsByIdentity[record.identityKey] = existing.merging(
                source: record.source,
                lastSeenAt: record.lastSeenAt,
                title: record.title,
                metadata: record.metadata,
                occurrenceIncrement: max(0, record.occurrenceCount - existing.occurrenceCount)
            )
        } else {
            recordsByIdentity[record.identityKey] = record
            nextOrder &+= 1
            orderByID[record.id] = nextOrder
        }
        let orderedRecords = ordered(recordsByIdentity.values)
        records = Array(orderedRecords.prefix(retentionLimit))
        recordsByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
        if records.count < orderedRecords.count {
            let liveIDs = Set(records.map(\.id))
            orderByID = orderByID.filter { liveIDs.contains($0.key) }
            titleStateByID = titleStateByID.filter { liveIDs.contains($0.key) }
            titleGenerationByID = titleGenerationByID.filter { liveIDs.contains($0.key) }
            activeTitleFetchIDByID = activeTitleFetchIDByID.filter { liveIDs.contains($0.key) }
            titleRetryAfterByID = titleRetryAfterByID.filter { liveIDs.contains($0.key) }
        }
    }

    func clearProjection() {
        records.removeAll(keepingCapacity: true)
        recordsByIdentity.removeAll(keepingCapacity: true)
        orderByID.removeAll(keepingCapacity: true)
        titleStateByID.removeAll()
        titleGenerationByID.removeAll()
        activeTitleFetchIDByID.removeAll()
        titleRetryAfterByID.removeAll()
    }

    func markStructuralChange() {
        structuralRevision &+= 1
        persistenceRevision &+= 1
    }

    func enqueue(record: ArtifactRecord) {
        enqueue(.record(record))
    }

    /// Queues every durable mutation through one ordered stream. The stream is
    /// fed only from the main actor, so remove/clear operations cannot overtake
    /// an earlier record write in a separately-created task.
    func enqueue(_ event: PersistenceEvent) {
        guard let continuation = persistenceContinuation else { return }
        if case .dropped = continuation.yield(event), !persistenceNeedsResync {
            persistenceNeedsResync = true
            _ = continuation.yield(.snapshot(records))
            persistenceNeedsResync = false
        }
    }

    func enqueueSnapshot() {
        guard let continuation = persistenceContinuation else { return }
        _ = continuation.yield(.snapshot(records))
    }

    func linkEntry(for record: ArtifactRecord) -> WorkspaceCapturedLink? {
        guard record.kind == .url || record.kind == .file else { return nil }
        let url: String
        switch record.representation {
        case .url(let value): url = value
        case .directory, .managedFile, .inlineText, .inlineHTML: return nil
        }
        let sourcePanelID = record.metadata[Self.sourcePanelMetadataKey].flatMap(UUID.init(uuidString:))
        let sourceTitle = record.metadata[Self.sourceTitleMetadataKey]
        let hostKey = URL(string: url).flatMap { hostPolicy.hostKey(for: $0.absoluteString) }
        let origin: WorkspaceCapturedLinkOrigin = record.source == .terminalOSC8 ? .osc8 : .detected
        return WorkspaceCapturedLink(
            id: record.id,
            url: url,
            hostKey: hostKey,
            firstSeen: record.createdAt,
            lastSeen: record.lastSeenAt,
            count: record.occurrenceCount,
            sourcePanelId: sourcePanelID,
            sourceSurfaceTitle: sourceTitle,
            origin: origin,
            fetchedTitle: record.title,
            titleFetchState: titleStateByID[record.id, default: .idle],
            titleFetchGeneration: titleGenerationByID[record.id, default: 0],
            activeTitleFetchID: activeTitleFetchIDByID[record.id],
            titleFetchRetryAfter: titleRetryAfterByID[record.id]
        )
    }

    func record(from entry: WorkspaceCapturedLink) -> ArtifactRecord {
        var metadata: [String: String] = [:]
        if let sourcePanelId = entry.sourcePanelId { metadata[Self.sourcePanelMetadataKey] = sourcePanelId.uuidString }
        if let sourceSurfaceTitle = entry.sourceSurfaceTitle { metadata[Self.sourceTitleMetadataKey] = sourceSurfaceTitle }
        return ArtifactRecord(
            id: entry.id,
            kind: entry.url.lowercased().hasPrefix("file://") ? .file : .url,
            identityKey: identity.key(kind: .url, value: entry.url, ownership: ownership),
            ownership: ownership,
            source: .migratedLink,
            createdAt: entry.firstSeen,
            lastSeenAt: entry.lastSeen,
            occurrenceCount: entry.count,
            title: entry.fetchedTitle,
            metadata: metadata,
            representation: .url(entry.url)
        )
    }

    func ordered<S: Sequence>(_ values: S) -> [ArtifactRecord] where S.Element == ArtifactRecord {
        values.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            let lhsOrder = orderByID[$0.id, default: 0]
            let rhsOrder = orderByID[$1.id, default: 0]
            if lhsOrder != rhsOrder { return lhsOrder > rhsOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
