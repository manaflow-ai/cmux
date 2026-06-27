public import Foundation

/// Seam satisfied by the app's session snapshot root (`AppSessionSnapshot`).
///
/// The repository is generic over this protocol so the snapshot DTO graph
/// (and therefore the on-disk wire format) stays owned by the app target:
/// the repository encodes and decodes whatever conforming value the app
/// hands it, byte-for-byte through the same `Codable` synthesis.
public protocol SessionSnapshotRepresenting: Codable, Sendable {
    /// The schema version persisted inside the snapshot payload.
    var version: Int { get }
    /// Whether the snapshot carries at least one window. A persisted
    /// snapshot with an empty window list is anomalous (empty states remove
    /// the file instead of writing it) and is treated as unusable.
    var hasWindows: Bool { get }
}

extension SessionSnapshotRepresenting {
    /// The schema version freshly created snapshots carry. Persisted
    /// snapshots whose `version` differs are treated as unusable. Faithful
    /// relocation of the legacy `SessionSnapshotSchema.currentVersion`
    /// constant from `Sources/SessionPersistence.swift`; the value is
    /// unchanged.
    public static var currentSchemaVersion: Int { 1 }
}
