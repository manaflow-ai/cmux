import Foundation

/// Versioned envelope used for bounded catalog decoding and future migrations.
struct ArtifactCatalogDocument: Codable, Sendable {
    let version: Int
    let records: [ArtifactRecord]

    init(version: Int = 1, records: [ArtifactRecord]) {
        self.version = version
        self.records = records
    }
}
