public import Foundation

/// Terminal scrollback position captured when a notification is recorded.
public struct TerminalNotificationScrollPosition: Codable, Hashable, Sendable {
    public let row: Int
    public let totalRows: Int?

    public init(row: Int, totalRows: Int? = nil) {
        self.row = row
        self.totalRows = totalRows
    }
}
