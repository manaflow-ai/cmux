import CmuxArtifacts
import Foundation

/// Bounded, portable artifact records embedded in a workspace session snapshot.
///
/// The process-wide catalog remains authoritative; this collection is a restart
/// handoff and migration envelope so a snapshot can restore records even when a
/// catalog write was interrupted.
struct SessionWorkspaceArtifactsSnapshotCollection: Codable, Sendable {
    static let maximumRecords = 10_000
    /// Inline bodies are useful for recovery when the catalog write was
    /// interrupted, but they must not turn the session manifest into a second
    /// binary store.
    static let maximumInlineBytes = 128 * 1024
    static let maximumSnapshotBytes = 16 * 1024 * 1024
    let records: [ArtifactRecord]

    init(_ records: [ArtifactRecord]) {
        var bounded: [ArtifactRecord] = []
        bounded.reserveCapacity(min(records.count, Self.maximumRecords))
        var estimatedBytes = 0
        for record in records.prefix(Self.maximumRecords) {
            let snapshotRecord = Self.bounded(record)
            let recordBytes = Self.estimatedBytes(snapshotRecord)
            guard estimatedBytes == 0 || estimatedBytes + recordBytes <= Self.maximumSnapshotBytes else {
                break
            }
            bounded.append(snapshotRecord)
            estimatedBytes += recordBytes
        }
        self.records = bounded
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [ArtifactRecord] = []
        values.reserveCapacity(min(container.count ?? 0, Self.maximumRecords))
        while !container.isAtEnd, values.count < Self.maximumRecords {
            // Do not swallow a malformed record: silently returning an empty
            // collection would erase historical artifacts on the next save.
            values.append(try container.decode(ArtifactRecord.self))
        }
        records = values
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for record in records.prefix(Self.maximumRecords) {
            try container.encode(record)
        }
    }

    private static func bounded(_ record: ArtifactRecord) -> ArtifactRecord {
        let representation: ArtifactRepresentation
        switch record.representation {
        case .inlineText(let value):
            representation = .inlineText(String(decoding: Array(value.utf8.prefix(Self.maximumInlineBytes)), as: UTF8.self))
        case .inlineHTML(let value):
            representation = .inlineHTML(String(decoding: Array(value.utf8.prefix(Self.maximumInlineBytes)), as: UTF8.self))
        case .url, .managedFile, .directory:
            representation = record.representation
        }
        return ArtifactRecord(
            id: record.id,
            kind: record.kind,
            identityKey: record.identityKey,
            ownership: record.ownership,
            source: record.source,
            createdAt: record.createdAt,
            lastSeenAt: record.lastSeenAt,
            occurrenceCount: record.occurrenceCount,
            title: record.title,
            metadata: record.metadata,
            representation: representation,
            isUserOwned: record.isUserOwned
        )
    }

    private static func estimatedBytes(_ record: ArtifactRecord) -> Int {
        let representationBytes: Int
        switch record.representation {
        case .url(let value), .directory(let value), .inlineText(let value), .inlineHTML(let value):
            representationBytes = value.utf8.count
        case .managedFile(let path, let name):
            representationBytes = path.utf8.count + name.utf8.count
        }
        let metadataBytes = record.metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        return max(1, representationBytes + metadataBytes + record.identityKey.utf8.count + 512)
    }
}
