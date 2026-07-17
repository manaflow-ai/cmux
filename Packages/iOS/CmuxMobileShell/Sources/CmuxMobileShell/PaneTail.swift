public import Foundation

/// Published terminal tail content for one Pane Rack surface.
public struct PaneTail: Equatable, Sendable {
    /// The most recent non-blank terminal rows within the active row budget.
    public var rows: [String]
    /// Timestamp of the most recently delivered render-grid frame.
    public var lastActivityAt: Date?
    /// Current terminal column count.
    public var columns: Int

    /// Creates published terminal tail content.
    /// - Parameters:
    ///   - rows: Most recent non-blank terminal rows.
    ///   - lastActivityAt: Timestamp of the most recently delivered frame.
    ///   - columns: Current terminal column count.
    public init(rows: [String], lastActivityAt: Date?, columns: Int) {
        self.rows = rows
        self.lastActivityAt = lastActivityAt
        self.columns = columns
    }
}
