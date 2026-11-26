import Foundation
import GhosttyNextKit

/// A terminal comment's place in the scrollback (Comment… on a selection, comment-threads-v1):
/// the rows the selection covered, in the scrollbar's numbering (row 0 the oldest the screen
/// keeps, as ``togglePlaceViewport()`` and Ghostty's `scroll_to_row`). The thread keeps them, and
/// Show on its card scrolls back to them and selects them again, even after output pushed them
/// off the screen.
extension TerminalSession {
    /// The rows the selection covers now; nil when nothing is selected or Ghostty reported no
    /// scrollbar yet. Reads the viewport once (one surface lock), on the person's Comment… click.
    public func commentAnchorRows() -> ClosedRange<Int>? {
        guard let surface = surfaceView.surface, let bar = model.scrollbar,
              let selection = TerminalSelection.read(surface), !selection.text.isEmpty,
              let grid = surfaceView.currentGrid else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_height > 0, metrics.cell_width > 0 else { return nil }
        // Ghostty reports the selection's top-left in points from the view's top-left, padding included.
        let guessRow = Int(((selection.topLeft.y - Double(metrics.padding_top)) / Double(metrics.cell_height)).rounded(.down))
        let startColumn = Int(((selection.topLeft.x - Double(metrics.padding_left)) / Double(metrics.cell_width)).rounded(.down))
        let viewport = viewportRows(surface)
        let row = TerminalCommentAnchor.locate(selection.text, in: viewport, near: guessRow) ?? guessRow
        guard row >= 0 else { return nil }
        let first = Int(bar.offsetRows) + row
        let span = TerminalCommentAnchor.rowSpan(of: selection.text, columns: grid.columns, startColumn: max(startColumn, 0))
        return first...(first + span - 1)
    }

    /// Scrolls `rows` back into view, a third of the way down, and selects them again. The rows
    /// are found by `quote`'s first line nearest where they were (trimmed history shifts every row
    /// up), so this says false when that text left the scrollback. One read of the screen.
    public func revealCommentAnchor(_ rows: ClosedRange<Int>, quote: String) -> Bool {
        guard let surface = surfaceView.surface, let bar = model.scrollbar else { return false }
        let start = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let end = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let screen = TerminalCommentAnchor.lines(rectangleText(surface, from: start, to: end) ?? "")
        guard let row = TerminalCommentAnchor.locate(quote, in: screen, near: rows.lowerBound) else { return false }
        let total = Int(bar.totalRows), visible = max(Int(bar.visibleRows), 1)
        let top = min(max(row - visible / 3, 0), max(total - visible, 0))
        _ = surfaceView.performBindingAction("scroll_to_row:\(top)")
        let column = TerminalCommentAnchor.column(of: quote, in: screen[row])
        guard let line = UInt16(exactly: row - top), let cell = UInt16(exactly: column),
              ghostty_surface_select_viewport_cell(surface, cell, line) else { return true }
        for _ in 0..<min(rows.count - 1, 4096) { _ = surfaceView.performBindingAction("adjust_selection:down") }
        _ = surfaceView.performBindingAction("adjust_selection:end_of_line")
        return true
    }

    private func viewportRows(_ surface: ghostty_surface_t) -> [String] {
        let start = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let end = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        return TerminalCommentAnchor.lines(rectangleText(surface, from: start, to: end) ?? "")
    }
}

/// The rows from `start` to `end` as a rectangle, one line per row (a plain read joins
/// soft-wrapped rows, so its line N is not row N).
@MainActor
private func rectangleText(_ surface: ghostty_surface_t, from start: ghostty_point_s, to end: ghostty_point_s) -> String? {
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(surface, ghostty_selection_s(top_left: start, bottom_right: end, rectangle: true), &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text, text.text_len > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
}

/// The text side of a comment's scrollback anchor, no surface: which row holds a quote, and how
/// many rows a quote covers.
public struct TerminalCommentAnchor {
    public init() {}
    /// Characters of a quote's first line a row must contain: short enough to sit in one row of
    /// any terminal wider than it, long enough that a prompt or blank does not match by chance.
    static let keyLength = 24

    /// One row per line.
    public static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.trimmingSuffix("\r")) }
    }

    /// The row of `rows` nearest `near` that holds the quote's first non-blank line (its first
    /// ``keyLength`` characters, without the surrounding blanks); nil when none does.
    public static func locate(_ quote: String, in rows: [String], near: Int) -> Int? {
        guard let key = key(of: quote) else { return nil }
        var best: Int?
        for (index, row) in rows.enumerated() where row.contains(key) {
            if best.map({ abs(index - near) < abs($0 - near) }) ?? true { best = index }
        }
        return best
    }

    /// The column where the quote's key starts in `row` (0 when it is not there).
    static func column(of quote: String, in row: String) -> Int {
        guard let key = key(of: quote), let range = row.range(of: key) else { return 0 }
        return row.distance(from: row.startIndex, to: range.lowerBound)
    }

    /// How many rows `quote` covers in a grid `columns` wide when its first line starts at
    /// `startColumn`: each line wraps every `columns` characters.
    public static func rowSpan(of quote: String, columns: Int, startColumn: Int) -> Int {
        let width = max(columns, 1)
        var body = Substring(quote)
        while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
        return lines(String(body)).enumerated().reduce(0) { total, line in
            let used = line.element.count + (line.offset == 0 ? startColumn : 0)
            return total + max(1, (used + width - 1) / width)
        }
    }

    private static func firstLine(of quote: String) -> Substring? {
        quote.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
    }

    private static func key(of quote: String) -> String? {
        guard let line = firstLine(of: quote) else { return nil }
        let trimmed = line.drop(while: \.isWhitespace)
        let key = String(trimmed.prefix(keyLength)).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }
}

private extension Substring {
    func trimmingSuffix(_ suffix: String) -> Substring {
        hasSuffix(suffix) ? dropLast(suffix.count) : self
    }
}
