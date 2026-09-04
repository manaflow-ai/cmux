import CmuxArtifacts
import Foundation

/// Bounded, portable artifact records embedded in a workspace session snapshot.
///
/// The process-wide catalog remains authoritative; this collection is a restart
/// handoff and migration envelope so a snapshot can restore records even when a
/// catalog write was interrupted.
struct SessionWorkspaceArtifactsSnapshotCollection: Codable, Sendable {
    static let maximumRecords = 10_000
    let records: [ArtifactRecord]

    init(_ records: [ArtifactRecord]) {
        self.records = Array(records.prefix(Self.maximumRecords))
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
}
