import Foundation

/// A pane's history length, width and screen, read in one `display-message`.
struct RemoteTmuxPaneHistoryShape: Equatable {
    let historySize: Int
    let paneWidth: Int
    let isAlternateScreen: Bool

    /// The format whose reply ``init(reply:)`` parses.
    static let format = "#{history_size} #{pane_width} #{alternate_on}"

    /// Parses `"<history_size> <pane_width> <alternate_on>"`; nil for anything else.
    init?(reply: String) {
        let fields = reply.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              let historySize = Int(fields[0]), historySize >= 0,
              let paneWidth = Int(fields[1]), paneWidth > 0
        else { return nil }
        self.historySize = historySize
        self.paneWidth = paneWidth
        self.isAlternateScreen = fields[2] == "1"
    }
}
