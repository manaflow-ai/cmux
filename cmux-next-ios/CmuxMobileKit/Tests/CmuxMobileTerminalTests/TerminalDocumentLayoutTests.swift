import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// SPEC B1: the document starts at the first row with text, never at the
/// blank mirror rows above the Mac's screen.
@Suite struct TerminalDocumentLayoutTests {
    private func leading(_ text: String, limit: Int = 200) -> Int {
        Array(text.utf8).withUnsafeBytes { TerminalDocumentLayout.leadingNewlines(in: $0, limit: limit) }
    }

    @Test func countsBlankRowsBeforeTheFirstText() {
        #expect(leading("\n\n\nLast login\n% ") == 3)
        #expect(leading("% ") == 0)
        #expect(leading("\n\n   indented") == 2)
        #expect(leading("") == 200)
        #expect(leading("\n\n\n", limit: 2) == 2)
    }

    @Test func shortRemoteSessionStartsAtItsFirstRow() {
        // 148-row mirror, Mac screen of 42 rows at the bottom: 106 blank rows,
        // then 10 lines with the cursor on the 10th.
        let layout = TerminalDocumentLayout.make(totalRows: 148, cursorRow: 115, leadingBlankRows: 106)
        #expect(layout.originRow == 106)
        #expect(layout.rowCount == 10)
        #expect(layout.contentY(ofRow: 106, cellHeight: 16) == 0)
        #expect(layout.row(atContentY: 33, cellHeight: 16) == 108)
        #expect(layout.row(atContentY: -50, cellHeight: 16) == 106)
    }

    @Test func clearPutsThePromptOnTheFirstRow() {
        // After `clear` only the prompt row is left, at the mirror offset.
        let layout = TerminalDocumentLayout.make(totalRows: 148, cursorRow: 106, leadingBlankRows: 148)
        #expect(layout.originRow == 106)
        #expect(layout.rowCount == 1)
    }

    @Test func localSessionHasNoOffset() {
        let layout = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 399, leadingBlankRows: 0)
        #expect(layout.originRow == 0)
        #expect(layout.rowCount == 400)
    }

    /// User report (2026-10-14): Codex CLI's cursor is in its input box with
    /// two hint rows drawn below it; those rows end the document, so the
    /// last one rests above the composer instead of under it.
    @Test func rowsDrawnBelowTheCursorEndTheDocument() {
        let layout = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 396, leadingBlankRows: 0, lastContentRow: 398)
        #expect(layout.endRow == 399)
        // Blank rows below the cursor do not.
        #expect(TerminalDocumentLayout.make(totalRows: 400, cursorRow: 396, leadingBlankRows: 0, lastContentRow: 390).endRow == 397)
    }

    @Test func unknownCursorUsesTheTotal() {
        let layout = TerminalDocumentLayout.make(totalRows: 50, cursorRow: nil, leadingBlankRows: 10)
        #expect(layout.originRow == 10)
        #expect(layout.endRow == 50)
    }

    @Test func shortDocumentRestsAtTheTopInset() {
        // 10 rows of 16.4 pt under a 62 pt top inset: never floats to the composer.
        let offset = TerminalDocumentLayout.bottomOffset(contentHeight: 164, viewportHeight: 874, topInset: 62, bottomInset: 140)
        #expect(offset == -62)
        // 1 page: the whole document fits between the insets.
        #expect(164 + 62 + 140 <= 874)
    }

    @Test func keyboardLiftsOnlyAsFarAsTheCursorNeeds() {
        // 30 rows (492 pt) with the keyboard up (bottom inset 424 pt): the
        // last row ends just above the composer, not one point higher.
        let offset = TerminalDocumentLayout.bottomOffset(contentHeight: 492, viewportHeight: 874, topInset: 62, bottomInset: 424)
        #expect(offset == 42)
        #expect(492 - offset == CGFloat(874 - 424))
        // Keyboard down again: back to the top inset.
        #expect(TerminalDocumentLayout.bottomOffset(contentHeight: 492, viewportHeight: 874, topInset: 62, bottomInset: 140) == -62)
    }

    @Test func originIsReadOnlyWhileItCanChange() {
        let onScreen = TerminalDocumentLayout(originRow: 106, endRow: 116)
        #expect(TerminalDocumentLayout.needsOriginScan(previous: nil, previousTotal: 0, totalRows: 148, screenRows: 148))
        #expect(TerminalDocumentLayout.needsOriginScan(previous: onScreen, previousTotal: 148, totalRows: 148, screenRows: 148))
        // Deep in the scrollback (a flood): no read.
        let scrolledAway = TerminalDocumentLayout(originRow: 106, endRow: 5000)
        #expect(!TerminalDocumentLayout.needsOriginScan(previous: scrolledAway, previousTotal: 4990, totalRows: 5000, screenRows: 148))
        // Cleared scrollback: read again.
        #expect(TerminalDocumentLayout.needsOriginScan(previous: scrolledAway, previousTotal: 5000, totalRows: 148, screenRows: 148))
    }
}

/// termqa D2: a following page jumped down 7 rows and back up while Codex
/// erased and redrew its live area below the cursor.
@Suite struct TerminalEndHoldTests {
    /// Mac screen of 42 rows at the bottom of a 400-row scrollback (top row 358).
    @Test func anInlineTUIRedrawDoesNotMoveTheEndUp() {
        var hold = TerminalEndHold()
        let drawn = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 390, leadingBlankRows: 0, lastContentRow: 396)
        #expect(hold.hold(drawn, totalRows: 400, cursorRow: 390, screenTopRow: 358).endRow == 397)
        // The live area is erased: the measured end moves up 7 rows; the held one does not.
        let erased = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 389, leadingBlankRows: 0, lastContentRow: nil)
        #expect(erased.endRow == 390)
        #expect(hold.hold(erased, totalRows: 400, cursorRow: 389, screenTopRow: 358).endRow == 397)
        // Lines committed above the live area grow the scrollback: the end moves with them.
        let grown = TerminalDocumentLayout.make(totalRows: 410, cursorRow: 399, leadingBlankRows: 0, lastContentRow: nil)
        #expect(hold.hold(grown, totalRows: 410, cursorRow: 399, screenTopRow: 368).endRow == 407)
        // Redrawn lower than before: the end follows down.
        let lower = TerminalDocumentLayout.make(totalRows: 410, cursorRow: 401, leadingBlankRows: 0, lastContentRow: 409)
        #expect(hold.hold(lower, totalRows: 410, cursorRow: 401, screenTopRow: 368).endRow == 410)
    }

    @Test func aClearedScreenLetsTheEndMoveUp() {
        var hold = TerminalEndHold()
        let full = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 399, leadingBlankRows: 0)
        _ = hold.hold(full, totalRows: 400, cursorRow: 399, screenTopRow: 358)
        // ^L: the cursor on the screen's first row; the prompt goes to the top, not held at the bottom.
        let cleared = TerminalDocumentLayout.make(totalRows: 400, cursorRow: 358, leadingBlankRows: 0)
        #expect(hold.hold(cleared, totalRows: 400, cursorRow: 358, screenTopRow: 358).endRow == 359)
        // `clear` with ESC [3J: the scrollback shrank.
        var hold2 = TerminalEndHold()
        _ = hold2.hold(full, totalRows: 400, cursorRow: 399, screenTopRow: 358)
        let reset = TerminalDocumentLayout.make(totalRows: 42, cursorRow: 1, leadingBlankRows: 0)
        #expect(hold2.hold(reset, totalRows: 42, cursorRow: 1, screenTopRow: 0).endRow == 2)
    }

    /// Round 8 (simulator, demo `rowprobe`): `clear` without ESC[3J and a
    /// prompt with a blank line above it (zsh with starship, the mock
    /// shell): the cursor lands on the screen's third row, not its first, so
    /// the end stayed held at the screen's bottom: a blank page with the
    /// prompt 148 rows above it.
    @Test func aClearedScreenWithATwoLinePromptLetsTheEndMoveUp() {
        var hold = TerminalEndHold()
        let full = TerminalDocumentLayout.make(totalRows: 1059, cursorRow: 1058, leadingBlankRows: 0)
        _ = hold.hold(full, totalRows: 1059, cursorRow: 1058, screenTopRow: 908)
        let cleared = TerminalDocumentLayout.make(totalRows: 1060, cursorRow: 911, leadingBlankRows: 0)
        #expect(hold.hold(cleared, totalRows: 1060, cursorRow: 911, screenTopRow: 909).endRow == 912)
        // A mirror: the Mac's 39-row screen, ^L with a two-line prompt.
        var mirror = TerminalEndHold()
        let bottom = TerminalDocumentLayout.make(totalRows: 500, cursorRow: 499, leadingBlankRows: 0)
        _ = mirror.hold(bottom, totalRows: 500, cursorRow: 499, screenTopRow: 461)
        let redrawn = TerminalDocumentLayout.make(totalRows: 500, cursorRow: 463, leadingBlankRows: 0)
        #expect(mirror.hold(redrawn, totalRows: 500, cursorRow: 463, screenTopRow: 461).endRow == 464)
    }

    @Test func aShortSessionStillEndsAtItsCursor() {
        var hold = TerminalEndHold()
        // A new shell: 3 rows of text at the top of a 42-row screen.
        let short = TerminalDocumentLayout.make(totalRows: 42, cursorRow: 2, leadingBlankRows: 0)
        #expect(hold.hold(short, totalRows: 42, cursorRow: 2, screenTopRow: 0).endRow == 3)
        let more = TerminalDocumentLayout.make(totalRows: 42, cursorRow: 8, leadingBlankRows: 0)
        #expect(hold.hold(more, totalRows: 42, cursorRow: 8, screenTopRow: 0).endRow == 9)
    }
}

/// User report 2026-10-14 (real iPhone): "the bottom of the terminal isn't
/// actually pinned to the composer bar, just the row above it". At the
/// bottom offset, the last row's bottom edge is the composer card's top
/// (0 pt gap, 0 pt overlap), keyboard up or down, composer 1, 3 or 6 lines.
@Suite struct TerminalComposerPinTests {
    @Test(arguments: [
        // (page height, composer card top): keyboard down 1/3/6 lines, keyboard up 1/3/6 lines.
        (CGFloat(874), CGFloat(737)), (874, 697), (874, 637),
        (874, 437), (874, 397), (874, 337),
    ])
    func theLastRowRestsOnTheComposer(page: CGFloat, composerTop: CGFloat) {
        let cell: CGFloat = 16
        let topInset: CGFloat = 62
        for rows in [3, 40, 600] {
            let layout = TerminalDocumentLayout(originRow: 100, endRow: 100 + rows)
            let content = layout.contentHeight(cellHeight: cell)
            let inset = TerminalDocumentLayout.bottomInset(pageHeight: page, composerTop: composerTop)
            let offset = TerminalDocumentLayout.bottomOffset(contentHeight: content, viewportHeight: page,
                                                             topInset: topInset, bottomInset: inset)
            // Page y of the last row's bottom edge.
            let lastRowBottom = layout.contentY(ofRow: layout.endRow, cellHeight: cell) - offset
            if content <= composerTop - topInset {
                // A short document starts at the top inset and never floats down.
                #expect(offset == -topInset)
            } else {
                #expect(abs(lastRowBottom - composerTop) <= 1, "rows \(rows): last row ends at \(lastRowBottom), composer at \(composerTop)")
            }
        }
    }
}

@Suite struct TerminalDocumentGrowthTests {
    @Test func aGestureGrowsTheEndByTheNewRows() {
        let layout = TerminalDocumentLayout(originRow: 10, endRow: 500)
        // 500 rows, the end 4 rows above the scrollback's end (a TUI's hints held).
        #expect(layout.grown(fromTotal: 504, toTotal: 510) == TerminalDocumentLayout(originRow: 10, endRow: 506))
        // No new rows (a viewport report while scrolling): unchanged.
        #expect(layout.grown(fromTotal: 504, toTotal: 504) == layout)
    }
}
