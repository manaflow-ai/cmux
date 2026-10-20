public import Foundation

/// A stable identifier for one pane on the canvas.
///
/// Wraps the panel UUID used elsewhere in cmux so the canvas model never
/// confuses pane identifiers with other UUID-keyed entities.
public struct CanvasPaneID: Hashable, Codable, Sendable, Comparable {
    /// The underlying panel UUID.
    public let rawValue: UUID

    /// Creates a pane identifier from a panel UUID.
    ///
    /// - Parameter rawValue: The panel UUID this pane represents.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Deterministic ordering by UUID string, used for stable tie-breaking.
    public static func < (lhs: CanvasPaneID, rhs: CanvasPaneID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}
