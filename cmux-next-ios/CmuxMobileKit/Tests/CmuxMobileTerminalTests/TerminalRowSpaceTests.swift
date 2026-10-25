@testable import CmuxMobileTerminal
import Testing

/// A model of Ghostty's row addressing through its C API
/// (`ghostty_surface_read_text`): every exact point's y is clamped to the
/// grid's last row (`embedded.zig` `Point.pin`), whatever its tag. Screen y
/// counts from the oldest kept row, active y from the active area's top
/// (the bottom `gridRows` rows) and viewport y from the viewport's top.
@MainActor
private final class GhosttyRowsModel: TerminalRowTextSource {
    var rows: [String]
    let gridRows: Int
    /// Nil: the viewport follows the active area.
    var viewportTop: Int?

    /// The absolute row the next line is written to (the cursor's row).
    private var cursor: Int

    init(rows: [String], gridRows: Int) {
        self.gridRows = gridRows
        cursor = rows.count
        // Ghostty always holds at least a screen of rows.
        self.rows = rows + Array(repeating: "", count: max(0, gridRows - rows.count))
    }

    var total: Int { rows.count }
    var activeTop: Int { total - gridRows }
    var top: Int { min(viewportTop ?? activeTop, activeTop) }
    var space: TerminalRowSpace { TerminalRowSpace(totalRows: total, gridRows: gridRows, viewportTop: top) }
    var reader: TerminalRowReader { TerminalRowReader(space: space, source: self) }

    private func clamp(_ y: Int) -> Int { min(y, gridRows - 1) }

    func text(_ row: TerminalViewportRow) -> String? { rows[top + clamp(row.index)] }
    func text(_ row: TerminalActiveRow) -> String? { rows[activeTop + clamp(row.index)] }
    func text(_ row: TerminalScreenRow) -> String? { rows[clamp(row.index)] }
    func text(screenRowsThrough last: TerminalScreenRow) -> String? {
        rows[0...clamp(last.index)].joined(separator: "\n")
    }

    /// Output: lines written at the cursor; past the screen's end the
    /// scrollback grows.
    func write(_ lines: [String]) {
        for line in lines {
            if cursor < total { rows[cursor] = line } else { rows.append(line) }
            cursor += 1
        }
    }

    /// `clear` without ESC[3J (ESC[H ESC[2J, ^L): Ghostty scrolls the
    /// active area's rows up into the scrollback and leaves a blank screen.
    func scrollClear() {
        rows = Array(rows[0..<min(cursor, total)]) + Array(repeating: "", count: gridRows)
        cursor = activeTop
    }

    /// ESC[3J: the scrollback is erased, the screen kept.
    func eraseScrollback() {
        cursor -= activeTop
        rows = Array(rows[activeTop...])
    }

    /// Ghostty prunes its oldest page once the scrollback is at its cap.
    func prune(_ count: Int) {
        rows.removeFirst(count)
        cursor -= count
        if let top = viewportTop { viewportTop = max(0, top - count) }
    }
}

private func numbered(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "#%07d", $0) } }

@MainActor
@Suite struct TerminalRowSpaceTests {
    /// Scrollback far longer than the grid: every addressable row reads its
    /// own text, and a row Ghostty cannot address reads as nil, never as
    /// another row.
    @Test func scrollbackRowsReadTheirOwnText() {
        let model = GhosttyRowsModel(rows: numbered(0...999), gridRows: 151)
        let reader = model.reader
        #expect(reader.text(TerminalAbsoluteRow(999)) == "#0000999")
        #expect(reader.text(TerminalAbsoluteRow(849)) == "#0000849")
        #expect(reader.text(TerminalAbsoluteRow(10)) == "#0000010")
        // In the scrollback, outside the viewport and past the screen's first rows.
        #expect(reader.text(TerminalAbsoluteRow(500)) == nil)
        model.viewportTop = 450
        #expect(model.reader.text(TerminalAbsoluteRow(500)) == "#0000500")
        #expect(model.reader.text(TerminalAbsoluteRow(1000)) == nil)
    }

    /// The round 8 symptom: after `clear` (no ESC[3J) the rows below the
    /// prompt are blank. The scan for an inline TUI's rows below the cursor
    /// must find none, so the document ends at the prompt instead of 150
    /// blank rows lower (a blank page with the prompt off screen).
    @Test func clearLeavesNoContentBelowThePrompt() {
        let model = GhosttyRowsModel(rows: numbered(0...599), gridRows: 151)
        model.scrollClear()
        model.write(["", "~/cmux-next on main", "❯ "])
        let cursor = TerminalAbsoluteRow(model.activeTop + 2)
        let reader = model.reader
        #expect(reader.text(cursor) == "❯ ")
        let below = reader.lastNonBlankRow(from: TerminalAbsoluteRow(cursor.index + 1), through: TerminalAbsoluteRow(model.total - 1))
        #expect(below == nil)
        let layout = TerminalDocumentLayout.make(totalRows: model.total, cursorRow: cursor.index, leadingBlankRows: 0,
                                                 lastContentRow: below?.index)
        #expect(layout.endRow == cursor.index + 1)
    }

    /// Codex's hint rows under its input box are found in the active area.
    @Test func rowsBelowTheCursorAreFoundInTheActiveArea() {
        let model = GhosttyRowsModel(rows: numbered(0...399), gridRows: 151)
        model.write(["› Ask Codex", "", "  ? for shortcuts"])
        let cursor = TerminalAbsoluteRow(model.total - 3)
        let found = model.reader.lastNonBlankRow(from: TerminalAbsoluteRow(cursor.index + 1), through: TerminalAbsoluteRow(model.total - 1))
        #expect(found == TerminalAbsoluteRow(model.total - 1))
    }

    /// The mirror's blank rows above the Mac's screen, with and without
    /// scrollback, and after ESC[3J.
    @Test func leadingBlankRowsCountsTheMirrorsUnwrittenRows() {
        let model = GhosttyRowsModel(rows: Array(repeating: "", count: 112) + numbered(1...20), gridRows: 151)
        #expect(model.reader.leadingBlankRows(through: TerminalAbsoluteRow(131)) == 112)
        model.write(numbered(21...400))
        #expect(model.total > 151)
        #expect(model.reader.leadingBlankRows(through: TerminalAbsoluteRow(model.total - 1)) == 112)
        model.eraseScrollback()
        #expect(model.reader.leadingBlankRows(through: TerminalAbsoluteRow(model.total - 1)) == 0)
    }

    /// History pruning drops the oldest rows: both the scrollbar's and the
    /// screen's numbering shift, the active area does not.
    @Test func pruningShiftsAbsoluteRowsWithTheText() {
        let model = GhosttyRowsModel(rows: numbered(0...4999), gridRows: 151)
        model.viewportTop = 3000
        #expect(model.reader.text(TerminalAbsoluteRow(3010)) == "#0003010")
        model.prune(1000)
        #expect(model.viewportTop == 2000)
        #expect(model.reader.text(TerminalAbsoluteRow(2010)) == "#0003010")
        #expect(model.reader.text(TerminalAbsoluteRow(model.total - 1)) == "#0004999")
        #expect(model.reader.text(TerminalAbsoluteRow(0)) == "#0001000")
    }

    @Test func spaceConvertsEachNumbering() {
        let space = TerminalRowSpace(totalRows: 456, gridRows: 151, viewportTop: 200)
        #expect(space.activeTop == 305)
        #expect(space.active(TerminalAbsoluteRow(305))?.index == 0)
        #expect(space.active(TerminalAbsoluteRow(304)) == nil)
        #expect(space.viewport(TerminalAbsoluteRow(350))?.index == 150)
        #expect(space.viewport(TerminalAbsoluteRow(351)) == nil)
        #expect(space.screen(TerminalAbsoluteRow(150))?.index == 150)
        #expect(space.screen(TerminalAbsoluteRow(151)) == nil)
        #expect(space.active(TerminalAbsoluteRow(456)) == nil)
        if let row = space.viewport(TerminalAbsoluteRow(250)) { #expect(space.absolute(row) == TerminalAbsoluteRow(250)) }
    }
}
