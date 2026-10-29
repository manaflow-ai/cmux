import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// PROTOCOL.md "Terminal sizing policy", "A grid larger than the phone": the
/// Mac's policy can keep a shared terminal at a grid that is not the
/// phone's. The phone renders that grid exactly (its mirror gets the Mac's
/// columns, so no line is rewrapped at the phone's width, which garbled
/// every TUI), panning sideways when it is wider and letterboxing when it
/// has fewer rows.
@Suite struct TerminalHostGridLayoutTests {
    /// An iPhone 17 Pro page: 390 pt of grid, 7.8 pt cells (50 columns), 40 TUI rows.
    let cell = CGSize(width: 7.8, height: 16)

    private func layout(host: (Int, Int)?, rows: Int = 40) -> TerminalHostGridLayout {
        TerminalHostGridLayout(viewportWidth: 390, cell: cell, scale: 3,
                               hostColumns: host?.0, hostRows: host?.1, visibleRows: rows)
    }

    @Test func withoutAHostGridTheMirrorIsThePhonesOwn() {
        let own = layout(host: nil)
        #expect(own.phoneColumns == 50)
        #expect(own.columns == 50)
        #expect(own.surfaceWidth == 390)
        #expect(own.maxPanX == 0)
        #expect(own.letterbox == nil)
        #expect(own.note(owner: "Mac") == nil)
    }

    @Test func theMacsOwnGridAtThePhonesWidthChangesNothing() {
        let same = layout(host: (50, 40))
        #expect(!same.followsHost)
        #expect(same.surfaceWidth == 390)
        #expect(!same.differsFromPhone)
    }

    @Test func aWiderHostGridGetsItsOwnColumnsAndPans() {
        let wide = layout(host: (120, 40))
        #expect(wide.columns == 120)
        #expect(wide.followsHost)
        // Ghostty fits floor(width / cell): exactly 120, never 50 (no rewrap).
        let pixels = wide.surfaceWidth * 3, cellPixels = cell.width * 3
        #expect(Int(floor(pixels / cellPixels)) == 120)
        #expect(abs(wide.maxPanX - (120 * 7.8 - 390)) < 0.001)
        #expect(wide.clampPan(-10) == 0)
        #expect(wide.clampPan(10_000) == wide.maxPanX)
    }

    @Test func aNarrowerHostGridKeepsItsColumnsAtTheLeadingEdge() {
        let narrow = layout(host: (40, 40))
        #expect(narrow.columns == 40)
        #expect(Int(floor(narrow.surfaceWidth * 3 / (cell.width * 3))) == 40)
        #expect(narrow.maxPanX == 0)
        #expect(narrow.differsFromPhone)
    }

    @Test func aGridTooWideForMetalIsCapped() {
        let huge = layout(host: (2000, 40))
        let widest = Int(floor(8192 / (cell.width * 3)))
        #expect(huge.columns == widest)
        #expect(huge.surfaceWidth * 3 <= 8192 + cell.width * 3)
    }

    @Test func typingPansOnlyAsFarAsTheCursorNeeds() {
        let wide = layout(host: (120, 40))
        // Visible: columns 0..<50. Column 10 shows: no pan.
        #expect(wide.pan(toShowColumn: 10, from: 0) == 0)
        // Column 80: its right edge plus a 4-cell margin at the page's right edge.
        let pan = wide.pan(toShowColumn: 80, from: 0)
        #expect(abs(pan - ((81 + 4) * 7.8 - 390)) < 0.001)
        // Back to column 2 from there: the margin, clamped at the leading edge.
        #expect(wide.pan(toShowColumn: 2, from: pan) == 0)
        // The last column: clamped to the end.
        #expect(wide.pan(toShowColumn: 119, from: 0) == wide.maxPanX)
        // A column already in view keeps a manual pan.
        #expect(wide.pan(toShowColumn: 30, from: 100) == 100)
    }

    @Test func fewerRowsAreLetterboxedBelowTheGrid() throws {
        let short = layout(host: (50, 20), rows: 40)
        let box = try #require(short.letterbox)
        let twentyRows: CGFloat = 20 * 16
        #expect(box.top == twentyRows)
        #expect(box.height == twentyRows)
        #expect(short.note(owner: "Aziz's Mac") == "50×20 · set by Aziz's Mac")
        #expect(short.note(owner: nil) == "50×20 · set by another device")
    }

    @Test func aTallerTUIShiftsOnlyToKeepTheCursorOnScreen() {
        let tall = layout(host: (50, 60), rows: 40)
        #expect(tall.letterbox == nil)
        #expect(tall.rowShift(keeping: 10, from: 0) == 0)
        // vim's status line (row 59) shows: the last 40 rows.
        #expect(tall.rowShift(keeping: 59, from: 0) == 20)
        // The cursor moves up within the shown rows: no jump.
        #expect(tall.rowShift(keeping: 30, from: 20) == 20)
        // Above them: just far enough.
        #expect(tall.rowShift(keeping: 5, from: 20) == 5)
        // Unknown cursor keeps the shift, clamped.
        #expect(tall.rowShift(keeping: nil, from: 99) == 20)
        #expect(layout(host: (50, 30), rows: 40).rowShift(keeping: 29, from: 3) == 0)
    }

    /// Review finding 6: a Mac grid wider than the widest surface the phone
    /// draws is not silently rewrapped: the layout says it is capped and the
    /// note names it.
    @Test func aGridWiderThanThePhoneCanDrawIsNamedInTheNote() {
        let wide = TerminalHostGridLayout(viewportWidth: 390, cell: CGSize(width: 7, height: 15), scale: 3,
                                          hostColumns: 500, hostRows: 20, visibleRows: 40)
        #expect(wide.isCapped)
        #expect(wide.columns == 390)
        #expect(wide.note(owner: "Studio") == "500×20, too wide for this iPhone (390 columns shown) · set by Studio")
        let fits = TerminalHostGridLayout(viewportWidth: 390, cell: CGSize(width: 7, height: 15), scale: 3,
                                          hostColumns: 120, hostRows: 20, visibleRows: 40)
        #expect(!fits.isCapped)
    }
}
