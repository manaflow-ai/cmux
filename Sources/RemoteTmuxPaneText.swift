import Foundation

/// One pane's text as plain lines, oldest first: its tmux history, then its screen.
///
/// Read with `capture-pane -p -J`, so wrapped rows are joined into the line the
/// program printed and there are no escape sequences. A line that wrapped across
/// two capture chunks arrives as two lines.
struct RemoteTmuxPaneText: Equatable, Sendable {
    /// History rows followed by screen rows, oldest first.
    let lines: [String]
    /// Whether tmux held more history than one read takes.
    let isTruncated: Bool
    /// Total UTF-8 bytes in ``lines``, for the reader's memory budget.
    let byteCount: Int

    init(lines: [String], isTruncated: Bool) {
        self.lines = lines
        self.isTruncated = isTruncated
        self.byteCount = lines.reduce(0) { $0 + $1.utf8.count }
    }
}
