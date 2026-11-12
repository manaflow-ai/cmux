import Testing
@testable import CmuxTerminalPrediction

private func glyphs(_ offsets: [Int], standing: PredictedGlyph.Standing = .speculative) -> [PredictedGlyph] {
    offsets.map { PredictedGlyph(character: "x", offset: $0, standing: standing) }
}

struct PredictionOverlayLayoutTests {
    @Test func aRunFromTheCursorEndsWithACaret() throws {
        let layout = try #require(PredictionOverlayLayout(glyphs: glyphs([0, 1, 2]), cursorColumn: 5, columns: 80))

        #expect(layout.glyphs.map(\.offset) == [0, 1, 2])
        #expect(layout.leadingOffset == 0)
        #expect(layout.caretOffset == 3)
        #expect(layout.cellCount == 4)
    }

    @Test func aHeldConfirmationExtendsTheOverlayLeftOfTheCursor() throws {
        let run = [
            PredictedGlyph(character: "a", offset: -1, standing: .confirmed),
            PredictedGlyph(character: "b", offset: 0, standing: .speculative),
        ]
        let layout = try #require(PredictionOverlayLayout(glyphs: run, cursorColumn: 5, columns: 80))

        #expect(layout.leadingOffset == -1)
        #expect(layout.caretOffset == 1)
        #expect(layout.cellCount == 3)
    }

    @Test func glyphsAfterAnUndrawnKeystrokeKeepTheirOffset() throws {
        // A keystroke typed before the run armed holds offset 0 undrawn; the
        // next glyph belongs one cell further on, not on the cursor.
        let layout = try #require(PredictionOverlayLayout(glyphs: glyphs([1]), cursorColumn: 5, columns: 80))

        #expect(layout.glyphs.map(\.offset) == [1])
        #expect(layout.leadingOffset == 1)
        #expect(layout.caretOffset == 2)
        #expect(layout.cellCount == 2)
    }

    @Test func nothingIsDrawnPastTheRightMargin() throws {
        // Columns 7, 8, 9 of a 10-column row fit; offset 3 would be column 10.
        let layout = try #require(PredictionOverlayLayout(glyphs: glyphs([0, 1, 2, 3]), cursorColumn: 7, columns: 10))

        #expect(layout.glyphs.map(\.offset) == [0, 1, 2])
        #expect(layout.caretOffset == nil)
        #expect(layout.cellCount == 3)
    }

    @Test func theCaretIsDroppedWhenItWouldLandPastTheMargin() throws {
        let layout = try #require(PredictionOverlayLayout(glyphs: glyphs([0]), cursorColumn: 8, columns: 10))

        #expect(layout.glyphs.map(\.offset) == [0])
        #expect(layout.caretOffset == 1)

        let full = try #require(PredictionOverlayLayout(glyphs: glyphs([0, 1]), cursorColumn: 8, columns: 10))
        #expect(full.caretOffset == nil)
        #expect(full.cellCount == 2)
    }

    @Test func noCaretLeftOfTheCursorWhileARetractedEchoAwaitsItsErase() throws {
        // The remote has printed a retracted character and not yet erased
        // it, so the held glyph sits two cells left of the cursor. Typing
        // continues where the erase will leave the cursor, not one cell left
        // of the live one; with nothing speculative, draw no caret there.
        let held = glyphs([-2], standing: .confirmed)
        let layout = try #require(PredictionOverlayLayout(glyphs: held, cursorColumn: 5, columns: 80))

        #expect(layout.glyphs.map(\.offset) == [-2])
        #expect(layout.caretOffset == nil)
        #expect(layout.cellCount == 1)

        // An ordinary held confirmation keeps its caret on the cursor.
        let ordinary = try #require(PredictionOverlayLayout(
            glyphs: glyphs([-1], standing: .confirmed),
            cursorColumn: 5,
            columns: 80
        ))
        #expect(ordinary.caretOffset == 0)
    }

    @Test func aCursorOnTheLastColumnDrawsNothing() {
        // It may be waiting to wrap, which moves every offset by a cell.
        #expect(PredictionOverlayLayout(glyphs: glyphs([0]), cursorColumn: 9, columns: 10) == nil)
        #expect(PredictionOverlayLayout(glyphs: glyphs([-1], standing: .confirmed), cursorColumn: 9, columns: 10) == nil)
    }

    @Test func confirmationsThatWrappedOffTheRowAreNotDrawn() throws {
        // The echo wrapped, so the cursor is on a new row and the oldest held
        // glyph belongs to the row above.
        let run = glyphs([-2, -1], standing: .confirmed) + glyphs([0])
        let layout = try #require(PredictionOverlayLayout(glyphs: run, cursorColumn: 1, columns: 80))

        #expect(layout.glyphs.map(\.offset) == [-1, 0])
        #expect(layout.leadingOffset == -1)
    }

    @Test func nothingToDrawIsNoLayout() {
        #expect(PredictionOverlayLayout(glyphs: [], cursorColumn: 0, columns: 80) == nil)
        #expect(PredictionOverlayLayout(glyphs: glyphs([0]), cursorColumn: 0, columns: 0) == nil)
        #expect(PredictionOverlayLayout(glyphs: glyphs([0]), cursorColumn: -1, columns: 80) == nil)
    }
}
