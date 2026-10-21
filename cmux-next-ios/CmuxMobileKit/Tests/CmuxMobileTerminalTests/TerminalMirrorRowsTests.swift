import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// Verifier defect V2-1 (VERIFY-round2.md): the tab grid's zoom lays the page
/// out at 893-963 pt, and the mirror's row count followed the page (151 ->
/// 157 rows). Ghostty resized the mirror mid-stream, which moved its rows
/// under the Mac's row mapping (TerminalRowShift: offset = mirror rows -
/// remote rows), so Codex's positioned writes landed on the wrong rows until
/// the next replay. The mirror's rows depend on the screen, never on a
/// transient page height.
@Suite struct TerminalMirrorRowsTests {
    let screen = CGSize(width: 402, height: 874)
    let cell: CGFloat = 16, scale: CGFloat = 3

    private func rows(page: CGFloat) -> Int {
        TerminalMirrorRows.rows(pageHeight: page, screenSize: screen, cellHeight: cell, scale: scale, marginRows: 48)
    }

    @Test func theGridZoomsPageHeightsKeepTheMirrorsRows() {
        let resting = rows(page: 874)
        #expect(resting == 55 + 96)
        for page in [893, 914, 939, 952, 963, 600, 402] as [CGFloat] {
            #expect(rows(page: page) == resting, "page \(page) pt")
        }
    }

    @Test func rotationKeepsTheMirrorsRows() {
        let portrait = rows(page: 874)
        let landscape = TerminalMirrorRows.rows(pageHeight: 402, screenSize: CGSize(width: 874, height: 402),
                                                cellHeight: cell, scale: scale, marginRows: 48)
        #expect(landscape == portrait)
    }

    @Test func aPageTallerThanTheScreenStillHasMarginRows() {
        // An unusual layout taller than the screen: the visible rows plus a
        // margin on each side are still covered.
        let tall = rows(page: 1400)
        #expect(tall >= Int((1400 / cell).rounded(.up)) + 2 * 24)
    }

    @Test func theMetalTextureLimitCapsTheRows() {
        let big = TerminalMirrorRows.rows(pageHeight: 874, screenSize: screen, cellHeight: 40, scale: 3, marginRows: 48)
        #expect(CGFloat(big) * 40 * 3 <= 8192)
    }
}
