/// Seam satisfied by the app's persisted window-geometry payload
/// (`AppDelegate.PersistedWindowGeometry`).
///
/// ``WindowGeometryStore`` is generic over this protocol so the geometry DTO
/// graph (`SessionRectSnapshot`/`SessionDisplaySnapshot` and the payload that
/// wraps them) and therefore the on-disk wire format stays owned by the app
/// target: the store encodes and decodes whatever conforming value the app
/// hands it, byte-for-byte through the same `Codable` synthesis. Only the
/// schema-version gate is shared logic, so the protocol exposes just `version`.
public protocol WindowGeometryPersisting: Codable, Sendable {
    /// The schema version persisted inside the geometry payload. A persisted
    /// payload whose version differs from the store's expected version is
    /// treated as unusable and discarded.
    var version: Int { get }
}
