import Foundation

/// One pane's text as plain lines, oldest first: its tmux history, then its screen.
///
/// Read with `capture-pane -p -J`, so wrapped rows are joined into the line the
/// program printed and there are no escape sequences. A line that wrapped across
/// two capture chunks arrives as two lines.
struct RemoteTmuxPaneText: Equatable, Sendable {
    /// History rows followed by screen rows, oldest first.
    let lines: [String]
    /// The pane's width in columns when it was read, for counting the rows a line wraps onto.
    let paneWidth: Int
    /// Whether tmux held more history than one read takes.
    let isTruncated: Bool
    /// Total UTF-8 bytes in ``lines``, for the reader's memory budget.
    let byteCount: Int

    init(lines: [String], paneWidth: Int, isTruncated: Bool) {
        self.lines = lines
        self.paneWidth = max(1, paneWidth)
        self.isTruncated = isTruncated
        self.byteCount = lines.reduce(0) { $0 + $1.utf8.count }
    }

    /// The most terminal rows `line` can take at ``paneWidth`` columns. A character
    /// outside ASCII is counted as two columns, the most any character takes, so this
    /// never comes out under the rows tmux wrapped the line onto.
    func maximumRows(of line: String) -> Int {
        let columns = line.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
        return max(1, (columns + paneWidth - 1) / paneWidth)
    }
}
