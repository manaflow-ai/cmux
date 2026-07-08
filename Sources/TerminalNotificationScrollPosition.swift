import Foundation

struct TerminalNotificationScrollPosition: Codable, Hashable, Sendable {
    let row: Int
    let totalRows: Int?

    init(row: Int, totalRows: Int? = nil) {
        self.row = row
        self.totalRows = totalRows
    }
}
