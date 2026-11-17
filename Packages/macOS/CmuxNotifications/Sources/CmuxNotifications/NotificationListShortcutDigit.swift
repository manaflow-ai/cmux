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

    /// The item a press of `digit` opens: the one the popover labelled with that digit when it
    /// last drew (`displayed`, the drawn rows' ids in order), looked up in `current`. Nil when no
    /// row shows the digit or that item is gone, so a press never opens a row it did not label.
    public static func item<Item, ID: Equatable>(
        forDigit digit: Int,
        displayed: [ID],
        current: [Item],
        id: (Item) -> ID
    ) -> Item? {
        guard let index = NotificationListShortcutDigit(rowCount: displayed.count).rowIndex(forDigit: digit)
        else { return nil }
        let target = displayed[index]
        return current.first { id($0) == target }
    }

    /// The digit shown on the row at `index`, or nil for a row no digit reaches.
    public func digit(forRowIndex index: Int) -> Int? {
        guard index >= 0, index < rowCount else { return nil }
        if index < Self.lastRowDigit - 1 { return index + 1 }
        return index == rowCount - 1 ? Self.lastRowDigit : nil
    }
}
