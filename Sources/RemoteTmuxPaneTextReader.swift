import CmuxRemoteSession
import Foundation

/// Reads one pane's full tmux history as plain text over the control stream.
///
/// The text comes in bounded chunks (see ``RemoteTmuxPaneHistoryPlan``), sized for
/// plain text rather than the seed's escape sequences. Each chunk is its own command and the next
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

    /// Reads `paneId`'s screen and history, taking their bytes from `budget`.
    ///
    /// The screen is read first and history newest first, so a pane that runs out of
    /// budget keeps its newest text and is marked truncated. Returns nil if the pane
    /// could not be read or its screen alone does not fit.
    func read(paneId: Int, budget: RemoteTmuxFindWindowTextBudget) async -> RemoteTmuxPaneText? {
        let shapeReply = await query(RemoteTmuxControlConnection.paneHistoryShapeQueryCommand(paneId: paneId))
        guard let line = shapeReply.lines?.first,
              let shape = RemoteTmuxPaneHistoryShape(reply: line) else { return nil }
        // A full-screen app's alternate screen has no history; tmux's own
        // find-window searches only the visible screen too.
        let plan = RemoteTmuxPaneHistoryPlan(
            historySize: shape.isAlternateScreen ? 0 : shape.historySize,
            paneWidth: shape.paneWidth,
            maximumCommandBlockBytes: RemoteTmuxControlStreamParser.defaultMaximumCommandBlockBytes,
            maximumRows: maximumRows,
            bytesPerCell: RemoteTmuxPaneHistoryPlan.plainTextBytesPerCell
        )
        guard !Task.isCancelled else { return nil }
        let screen = await query("capture-pane -p -J -t %\(paneId)")
        guard let screenRows = screen.lines.map(Self.droppingTrailingBlankRows),
              budget.take(Self.byteCount(of: screenRows)) else { return nil }
        // Newest chunk first; the first one that does not fit ends the read.
        var newestFirst: [[String]] = []
        var isCut = false
        for chunk in plan.chunks.reversed() {
            guard !Task.isCancelled else { return nil }
            let reply = await query("capture-pane -p -J \(chunk.captureArguments) -t %\(paneId)")
            guard let rows = reply.lines else { return nil }
            guard budget.take(Self.byteCount(of: rows)) else {
                isCut = true
                break
            }
            newestFirst.append(rows)
        }
        let lines = newestFirst.reversed().flatMap { $0 } + screenRows
        return RemoteTmuxPaneText(lines: lines, paneWidth: shape.paneWidth, isTruncated: plan.isTruncated || isCut)
    }

    private static func byteCount(of rows: [String]) -> Int {
        rows.reduce(0) { $0 + $1.utf8.count }
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
