import Foundation

struct TerminalNotificationScrollPosition: Codable, Hashable, Sendable {
    let row: Int
    let totalRows: Int?
    /// Replay generation active when this position was captured. A nil value
    /// represents positions captured before generation tracking was available.
    let replayGeneration: String?

    init(row: Int, totalRows: Int? = nil, replayGeneration: String? = nil) {
        self.row = row
        self.totalRows = totalRows
        self.replayGeneration = replayGeneration
    }
}
