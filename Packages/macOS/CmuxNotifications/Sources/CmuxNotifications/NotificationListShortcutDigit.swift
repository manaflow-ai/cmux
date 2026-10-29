import Foundation

/// The numbering the notifications popover uses for its rows while it is open: the same one the
/// workspace shortcuts use, so 1 through 8 select the rows in order and 9 selects the last row.
public struct NotificationListShortcutDigit: Sendable, Equatable {
    /// The digit that always selects the last row.
    public static let lastRowDigit = 9

    /// How many rows the popover lists.
    public let rowCount: Int

    /// Creates the numbering for a list of `rowCount` rows.
    public init(rowCount: Int) {
        self.rowCount = max(0, rowCount)
    }

    /// The index of the row `digit` selects, or nil when no row answers to it.
    public func rowIndex(forDigit digit: Int) -> Int? {
        guard rowCount > 0, (1...Self.lastRowDigit).contains(digit) else { return nil }
        if digit == Self.lastRowDigit { return rowCount - 1 }
        return digit <= rowCount ? digit - 1 : nil
    }

    /// The digit shown on the row at `index`, or nil for a row no digit reaches.
    public func digit(forRowIndex index: Int) -> Int? {
        guard index >= 0, index < rowCount else { return nil }
        if index < Self.lastRowDigit - 1 { return index + 1 }
        return index == rowCount - 1 ? Self.lastRowDigit : nil
    }
}
