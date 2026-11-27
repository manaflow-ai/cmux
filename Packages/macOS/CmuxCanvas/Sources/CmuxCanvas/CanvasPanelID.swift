public import Foundation

/// A stable identifier for one panel (tab) hosted by a canvas pane.
///
/// Distinct from ``CanvasPaneID``: a pane is the floating rect on the
/// canvas, a panel is one tab inside it. A single-tab pane created from a
/// panel reuses the panel's UUID as its pane identifier, but the two
/// identifier spaces must never be conflated once panes hold multiple tabs.
public struct CanvasPanelID: Hashable, Codable, Sendable, Comparable {
    /// The underlying panel UUID.
    public let rawValue: UUID

    /// Creates a panel identifier from a panel UUID.
    ///
    /// - Parameter rawValue: The panel UUID.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Deterministic ordering by UUID string, used for stable tie-breaking.
    public static func < (lhs: CanvasPanelID, rhs: CanvasPanelID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}
