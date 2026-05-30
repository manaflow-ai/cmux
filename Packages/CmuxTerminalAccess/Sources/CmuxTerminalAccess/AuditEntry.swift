import Foundation

/// One audit entry — one JSON line in the on-disk log (D3).
///
/// Encodes ``surface`` as its canonical ``SurfaceHandle`` string form
/// (`<uuid>` or `<kind>:<ordinal>`). `byte_count` and `detail` are
/// snake_cased on the wire.
public struct AuditEntry: Sendable, Codable, Equatable {
    /// When the action was performed.
    public let timestamp: Date
    /// Target surface.
    public let surface: SurfaceHandle
    /// Action taxonomy (``AuditKind``).
    public let kind: AuditKind
    /// Byte count of the action's payload (0 for events without a
    /// payload, like `stream_open`).
    public let byteCount: Int
    /// Optional flat string detail map (for example, `["submit":
    /// "true"]` on text writes).
    public let detail: [String: String]?

    /// Creates an audit entry.
    public init(
        timestamp: Date,
        surface: SurfaceHandle,
        kind: AuditKind,
        byteCount: Int,
        detail: [String: String]?
    ) {
        self.timestamp = timestamp
        self.surface = surface
        self.kind = kind
        self.byteCount = byteCount
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, surface, kind
        case byteCount = "byte_count"
        case detail
    }
}
