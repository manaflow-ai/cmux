import Foundation

struct TerminalNotificationScrollPosition: Codable, Hashable, Sendable {
    let row: Int
    let totalRows: Int?
    /// Replay generation active when this position was captured. A nil value
    /// represents positions captured before generation tracking was available.
    let replayGeneration: String?
    /// Identity of the absolute terminal row space at capture time.
    let rowSpaceRevision: UInt64?

    init(
        row: Int,
        totalRows: Int? = nil,
        replayGeneration: String? = nil,
        rowSpaceRevision: UInt64? = nil
    ) {
        self.row = row
        self.totalRows = totalRows
        self.replayGeneration = replayGeneration
        self.rowSpaceRevision = rowSpaceRevision
    }
}
