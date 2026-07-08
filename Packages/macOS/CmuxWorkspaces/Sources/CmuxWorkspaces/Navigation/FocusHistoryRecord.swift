public import Foundation

/// A focus-history entry plus the time the focus landed, as stored in the
/// back/forward stack.
public struct FocusHistoryRecord: Equatable, Sendable {
    /// The focused workspace/panel position.
    public let entry: FocusHistoryEntry
    /// When the focus landed.
    public var focusedAt: Date

    /// Creates a record; `focusedAt` defaults to now.
    public init(entry: FocusHistoryEntry, focusedAt: Date = Date()) {
        self.entry = entry
        self.focusedAt = focusedAt
    }
}
