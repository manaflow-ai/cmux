import Foundation

struct TerminalNotificationScrollPosition: Codable, Hashable, Sendable {
    let row: Int
    let totalRows: Int?
    let rowSpaceRevision: UInt64?

    init(row: Int, totalRows: Int? = nil, rowSpaceRevision: UInt64? = nil) {
        self.row = row
        self.totalRows = totalRows
        self.rowSpaceRevision = rowSpaceRevision
    }
}
