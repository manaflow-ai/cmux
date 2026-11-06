import Testing
@testable import CmuxMobileTerminal

/// Copy Mode (the Mac's Toggle Copy Mode, Select Text… on the phone): vi keys over the rows,
/// scrollback included, a visual selection, and the cells `y` copies.
@Suite struct TerminalCopyModeTests {
    let rows = ["$ make build", "error: foo.c:12 missing ;", "", "  done in 3s"]
    var lines: (Int) -> String { { row in rows.indices.contains(row) ? rows[row] : "" } }

    func apply(_ mode: inout TerminalCopyMode, _ keys: [TerminalCopyMode.Key]) -> TerminalCopyMode.Outcome {
        var last = TerminalCopyMode.Outcome.moved
        for key in keys { last = mode.apply(key, rows: 0..<rows.count, columns: 40, line: lines) }
        return last
    }

    @Test func hardwareKeysMapToMotions() {
        #expect(TerminalCopyMode.key(characters: "h", usage: 0x0B) == .left)
        #expect(TerminalCopyMode.key(characters: "j", usage: 0x0D) == .down)
        #expect(TerminalCopyMode.key(characters: "k", usage: 0x0E) == .up)
        #expect(TerminalCopyMode.key(characters: "l", usage: 0x0F) == .right)
        #expect(TerminalCopyMode.key(characters: "w", usage: 0x1A) == .wordForward)
        #expect(TerminalCopyMode.key(characters: "b", usage: 0x05) == .wordBackward)
        #expect(TerminalCopyMode.key(characters: "0", usage: 0x27) == .lineStart)
        #expect(TerminalCopyMode.key(characters: "$", usage: 0x21) == .lineEnd)
        #expect(TerminalCopyMode.key(characters: "g", usage: 0x0A) == .top)
        #expect(TerminalCopyMode.key(characters: "G", usage: 0x0A) == .bottom)
        #expect(TerminalCopyMode.key(characters: "v", usage: 0x19) == .toggleVisual)
        #expect(TerminalCopyMode.key(characters: "y", usage: 0x1C) == .yank)
        #expect(TerminalCopyMode.key(characters: "", usage: 0x29) == .exit)
        #expect(TerminalCopyMode.key(characters: "", usage: 0x52) == .up)
        #expect(TerminalCopyMode.key(characters: "x", usage: 0x1B) == nil)
    }

    @Test func motionsStayInTheDocument() {
        var mode = TerminalCopyMode(cursor: TerminalCellPoint(row: 1, column: 3))
        _ = apply(&mode, [.up, .up, .up])
        #expect(mode.cursor == TerminalCellPoint(row: 0, column: 3))
        _ = apply(&mode, [.left, .left, .left, .left, .left])
        #expect(mode.cursor.column == 0)
        _ = apply(&mode, [.bottom])
        #expect(mode.cursor == TerminalCellPoint(row: 3, column: 0))
        _ = apply(&mode, [.down, .lineEnd])
        #expect(mode.cursor == TerminalCellPoint(row: 3, column: 11))
        _ = apply(&mode, [.top, .lineEnd])
        #expect(mode.cursor == TerminalCellPoint(row: 0, column: 11))
        _ = apply(&mode, [.lineStart])
        #expect(mode.cursor.column == 0)
    }

    @Test func wordMotionsCrossRowsAndPunctuation() {
        var mode = TerminalCopyMode(cursor: TerminalCellPoint(row: 0, column: 0))
        _ = apply(&mode, [.wordForward])
        #expect(mode.cursor == TerminalCellPoint(row: 0, column: 2)) // make
        _ = apply(&mode, [.wordForward, .wordForward])
        #expect(mode.cursor == TerminalCellPoint(row: 1, column: 0)) // error (next row)
        _ = apply(&mode, [.wordForward])
        #expect(mode.cursor == TerminalCellPoint(row: 1, column: 5)) // ":"
        _ = apply(&mode, [.wordBackward])
        #expect(mode.cursor == TerminalCellPoint(row: 1, column: 0))
        _ = apply(&mode, [.wordBackward])
        #expect(mode.cursor == TerminalCellPoint(row: 0, column: 7)) // build
        // From the last ";", past the blank row to the next word.
        mode.cursor = TerminalCellPoint(row: 1, column: 24)
        _ = apply(&mode, [.wordForward])
        #expect(mode.cursor == TerminalCellPoint(row: 3, column: 2))
    }

    @Test func visualSelectionYanksItsCells() {
        var mode = TerminalCopyMode(cursor: TerminalCellPoint(row: 1, column: 7))
        #expect(!mode.isVisual)
        _ = apply(&mode, [.toggleVisual, .lineEnd])
        #expect(mode.isVisual)
        #expect(mode.selection == TerminalTextSelection(anchor: TerminalCellPoint(row: 1, column: 7), head: TerminalCellPoint(row: 1, column: 24)))
        let outcome = apply(&mode, [.yank])
        #expect(outcome == .copy(from: TerminalCellPoint(row: 1, column: 7), to: TerminalCellPoint(row: 1, column: 24)))
        // Backwards: the copy still runs start to end.
        var back = TerminalCopyMode(cursor: TerminalCellPoint(row: 3, column: 4))
        let up = apply(&back, [.toggleVisual, .up, .up, .yank])
        #expect(up == .copy(from: TerminalCellPoint(row: 1, column: 4), to: TerminalCellPoint(row: 3, column: 4)))
        // No selection: y copies the cursor's row.
        var line = TerminalCopyMode(cursor: TerminalCellPoint(row: 0, column: 5))
        #expect(apply(&line, [.yank]) == .copy(from: TerminalCellPoint(row: 0, column: 0), to: TerminalCellPoint(row: 0, column: 39)))
        // v again ends the selection; Escape leaves.
        _ = apply(&mode, [.toggleVisual])
        #expect(!mode.isVisual)
        #expect(apply(&mode, [.exit]) == .exit)
    }
}
