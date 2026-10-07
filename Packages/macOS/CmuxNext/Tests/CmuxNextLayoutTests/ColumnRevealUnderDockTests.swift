import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Reveal and snapping under floating side docks (layout-model.md F6): the
/// uncovered window, not the whole viewport, decides what is visible.
@Suite struct ColumnRevealUnderDockTests {
    /// 1000 wide viewport, gap 6, columns 400 wide; a floating left dock
    /// covers 300 and a floating right dock 200 of the viewport.
    private func strip(lead: CGFloat = 300, trail: CGFloat = 200) -> ColumnStrip {
        let frames = (0..<5).map { CGRect(x: 6 + CGFloat($0) * 406, y: 0, width: 400, height: 600) }
        var strip = ColumnStrip(columns: frames.enumerated().map { ColumnStrip.Column(id: ColumnID("c\($0.offset)"), frame: $0.element) },
                                viewportWidth: 1000, contentWidth: 6 + 5 * 406, gap: 6)
        strip.leadingCover = lead
        strip.trailingCover = trail
        return strip
    }

    @Test func aColumnUnderTheDockIsNotVisible() {
        // At offset 0, column 0 (6...406) sits under the left dock (0...300).
        #expect(!strip().isColumnVisible(0, at: 0))
        #expect(strip(lead: 0, trail: 0).isColumnVisible(0, at: 0))
    }

    @Test func revealMovesAColumnOutFromUnderTheDock() {
        let s = strip()
        // Column 2 (818...1218) at offset 600: window 900...1700, so its left
        // edge is under the left dock; the reveal aligns it to the window.
        let target = ColumnViewOffset.fit(s.columns[2].frame, current: 600, strip: s)
        #expect(abs(target - (818 - 6 - 300)) < 0.01)
        #expect(s.isColumnVisible(2, at: target))
    }

    @Test func aFullyUncoveredColumnDoesNotMove() {
        let s = strip()
        // Window at offset 500 is 800...1300; column 2 with padding is 812...1224.
        #expect(ColumnViewOffset.fit(s.columns[2].frame, current: 500, strip: s) == 500)
    }

    @Test func snapsAlignColumnsToTheUncoveredWindow() {
        let snaps = ColumnViewOffset.snaps(strip: strip(), mode: .never).map(\.offset)
        // Column 2's left alignment puts its padded edge at the window start.
        #expect(snaps.contains { abs($0 - (818 - 6 - 300)) < 0.01 })
        // Its right alignment puts its padded edge at the window end (1000 - 200).
        #expect(snaps.contains { abs($0 - (1218 + 6 - 500 - 300)) < 0.01 })
    }

    @Test func withoutCoversNothingChanges() {
        let s = strip(lead: 0, trail: 0)
        #expect(ColumnViewOffset.fit(s.columns[2].frame, current: 600, strip: s) == 600)
        #expect(abs(ColumnViewOffset.fit(s.columns[4].frame, current: 0, strip: s) - (2030 + 6 - 1000)) < 0.01)
    }
}
