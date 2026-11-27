import CmuxMobileDiff
import Foundation
import Testing

@Suite struct DiffLayoutTests {
    @Test func tabsExpandAndHighlightsFollow() {
        // "\tab" with "ab" highlighted: the tab becomes 4 spaces, so the highlight moves by 3.
        let display = DiffLayout.display(text: "\tab", highlights: [1..<3])
        #expect(display.text == "    ab")
        #expect(display.highlights == [4..<6])
        #expect(display.indent == 4)
    }

    @Test func tabStopsAlignToColumns() {
        let display = DiffLayout.display(text: "ab\tc", highlights: [3..<4])
        #expect(display.text == "ab  c")
        #expect(display.highlights == [4..<5])
        #expect(display.indent == 0)
    }

    @Test func outOfRangeHighlightsAreDropped() {
        let display = DiffLayout.display(text: "abc", highlights: [2..<9, 1..<1])
        #expect(display.highlights.isEmpty)
    }

    @Test func blankLineHasNoIndent() {
        #expect(DiffLayout.display(text: "    ", highlights: []).indent == 0)
    }

    @Test func longestLineSetsContentWidth() {
        let lines = [
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "short"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 2, text: String(repeating: "x", count: 120)),
        ]
        let width = DiffLayout.codeContentWidth(lines: lines, charWidth: 8, viewport: 402)
        #expect(width == 120 * 8 + DiffLayout.codeTrailingPadding)
    }

    @Test func shortContentFillsTheViewport() {
        let lines = [DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "a")]
        let width = DiffLayout.codeContentWidth(lines: lines, charWidth: 8, viewport: 402)
        #expect(width == 402 - DiffLayout.gutterWidth)
    }

    @Test func gutterIsTwoNumbersAndTheMarker() {
        #expect(DiffLayout.gutterWidth == 94)
        #expect(DiffLayout.codeViewport(width: 402) == 308)
    }

    @Test func rowHeightRoundsUp() {
        #expect(DiffLayout.rowHeight(lineHeight: 15.5) == 20)
    }

    @Test func hangingIndentMatchesLeadingWhitespace() {
        let display = DiffLayout.display(text: "        return MacLink(stream: channel)", highlights: [])
        #expect(DiffLayout.hangingIndent(display, charWidth: 8, codeWidth: 300) == 64)
    }

    @Test func hangingIndentIsCapped() {
        let display = DiffLayout.display(text: String(repeating: " ", count: 40) + "x", highlights: [])
        #expect(DiffLayout.hangingIndent(display, charWidth: 8, codeWidth: 300) == 150)
    }

    @Test func wrappedRowCountUsesTheIndentedColumn() {
        // 8 indent + 40 chars; width 300 at 8 pt per char = 37 columns, 29 after the 64 pt indent.
        let display = DiffLayout.display(text: String(repeating: " ", count: 8) + String(repeating: "a", count: 40), highlights: [])
        #expect(DiffLayout.wrappedRowCount(display, charWidth: 8, codeWidth: 300) == 2)
        let short = DiffLayout.display(text: "let a = 1", highlights: [])
        #expect(DiffLayout.wrappedRowCount(short, charWidth: 8, codeWidth: 300) == 1)
    }

    @Test func splitOnlyWhereTwoColumnsFit() {
        #expect(!DiffLayout.allowsSplit(width: 402))
        #expect(DiffLayout.allowsSplit(width: 820))
    }
}
