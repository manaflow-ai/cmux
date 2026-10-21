import Foundation

/// Reads one pane's full tmux history as plain text over the control stream.
///
/// The text comes in the same bounded chunks the full-history seed uses (see
/// ``RemoteTmuxPaneHistoryPlan``), but each chunk is its own command and the next
/// one is sent only after the previous reply arrives. Keystrokes, resizes and
/// other panes' commands queue between chunks instead of behind one large reply,
/// and at most one chunk per reader is ever in flight on the stream.
///
/// Rows can scroll into history between two chunks. The search this feeds can
/// then see a row twice or miss one at a chunk edge; it never reads past the
/// pane's history.
@MainActor
struct RemoteTmuxPaneTextReader {
    /// Sends one command and returns its reply.
    let query: @MainActor (_ command: String) async -> RemoteTmuxRawQueryOutcome
    /// The most history rows read per pane.
    var maximumRows = RemoteTmuxPaneHistoryPlan.maximumRows

    /// Reads `paneId`'s history and screen, or nil if the pane could not be read.
    func read(paneId: Int) async -> RemoteTmuxPaneText? {
        let shapeReply = await query(RemoteTmuxControlConnection.paneHistoryShapeQueryCommand(paneId: paneId))
        guard let line = shapeReply.lines?.first,
              let shape = RemoteTmuxPaneHistoryShape(reply: line) else { return nil }
        // A full-screen app's alternate screen has no history; tmux's own
        // find-window searches only the visible screen too.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: shape.isAlternateScreen ? 0 : shape.historySize,
            paneWidth: shape.paneWidth,
            maximumRows: maximumRows
        )
        var lines: [String] = []
        for chunk in plan.chunks {
            guard !Task.isCancelled else { return nil }
            let reply = await query("capture-pane -p -J \(chunk.captureArguments) -t %\(paneId)")
            guard let rows = reply.lines else { return nil }
            lines.append(contentsOf: rows)
        }
        guard !Task.isCancelled else { return nil }
        let screen = await query("capture-pane -p -J -t %\(paneId)")
        guard let screenRows = screen.lines else { return nil }
        lines.append(contentsOf: Self.droppingTrailingBlankRows(screenRows))
        return RemoteTmuxPaneText(lines: lines, isTruncated: plan.isTruncated)
    }

    /// A screen that is not full ends in blank rows; they match nothing and only
    /// push real rows further from the bottom.
    private static func droppingTrailingBlankRows(_ rows: [String]) -> [String] {
        var end = rows.endIndex
        while end > rows.startIndex,
              rows[rows.index(before: end)].allSatisfy({ $0 == " " || $0 == "\t" }) {
            end = rows.index(before: end)
        }
        return Array(rows[..<end])
    }
}
