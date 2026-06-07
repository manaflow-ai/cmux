import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalLetterboxGeometry pixel math")
struct TerminalLetterboxGeometryTests {
    @Test("drawable container subtracts keyboard overlap and floors at 1")
    func drawableContainer() {
        let full = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 0
        )
        #expect(full == CGSize(width: 402, height: 700))

        let withKeyboard = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 300
        )
        #expect(withKeyboard == CGSize(width: 402, height: 400))
    }

    @Test("keyboard taller than bounds is clamped so height stays >= 1")
    func keyboardClamp() {
        let clamped = TerminalLetterboxGeometry.drawableContainerSize(
            bounds: CGSize(width: 402, height: 700),
            keyboardHeight: 5000
        )
        // bottomInset clamps to height-1 = 699, container height = 700-699 = 1.
        #expect(clamped == CGSize(width: 402, height: 1))
    }

    @Test("container pixel size floors point*scale")
    func containerPixels() {
        let px = TerminalLetterboxGeometry.containerPixelSize(
            container: CGSize(width: 402, height: 400),
            scale: 3
        )
        #expect(px.width == 1206)
        #expect(px.height == 1200)

        // Fractional point sizes floor, not round.
        let frac = TerminalLetterboxGeometry.containerPixelSize(
            container: CGSize(width: 100.9, height: 50.4),
            scale: 2
        )
        #expect(frac.width == 201) // floor(201.8)
        #expect(frac.height == 100) // floor(100.8)
    }

    @Test("grid request pixel size floors cols*cellWidth")
    func gridRequest() {
        let px = TerminalLetterboxGeometry.gridRequestPixelSize(
            cols: 80,
            rows: 24,
            cellPixelSize: CGSize(width: 9.6, height: 20.0)
        )
        #expect(px.width == 768) // floor(80 * 9.6 = 768.0)
        #expect(px.height == 480) // 24 * 20
    }

    @Test("cell pixel size divides measured extent by grid counts")
    func cellPixels() {
        let cell = TerminalLetterboxGeometry.cellPixelSize(
            columns: 80, rows: 24, widthPx: 768, heightPx: 480
        )
        #expect(cell == CGSize(width: 9.6, height: 20.0))
    }

    @Test("cell pixel size is zero when any dimension is non-positive")
    func cellPixelsZero() {
        #expect(TerminalLetterboxGeometry.cellPixelSize(columns: 0, rows: 24, widthPx: 768, heightPx: 480) == .zero)
        #expect(TerminalLetterboxGeometry.cellPixelSize(columns: 80, rows: 24, widthPx: 0, heightPx: 480) == .zero)
    }

    @Test("no pin when effective grid fills the natural grid")
    func noPinWhenFills() {
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 100, rows: 40),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    @Test("no pin when effective grid is within one cell of natural")
    func noPinWithinOneCell() {
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 99, rows: 39),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    @Test("pins to a smaller effective grid producing a point-size box")
    func pinsSmallerGrid() {
        // effective 60x30, natural 100x40, cell 9x18 px at scale 3.
        // pinnedW = 60 * 9 / 3 = 180, pinnedH = 30 * 18 / 3 = 180.
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 60, rows: 30),
            measuredColumns: 100,
            measuredRows: 40,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == CGSize(width: 180, height: 180))
    }

    @Test("no pin when the pinned box is not meaningfully smaller than the container")
    func noPinWhenNotSmaller() {
        // pinnedW = 134*9/3 = 402 == container width, pinnedH = 233*18/3 ≈ 1398 > container.
        // Both axes fail the (pinned + 0.5 < container) test on width and natural
        // fills, so confirm a near-equal box does not pin.
        let pinned = TerminalLetterboxGeometry.pinnedPointSize(
            effective: (cols: 134, rows: 116),
            measuredColumns: 134,
            measuredRows: 116,
            cell: CGSize(width: 9, height: 18),
            scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(pinned == nil)
    }

    @Test("clampPinnedSize bounds refined pixels by the container")
    func clampPinned() {
        // refined 540x540 px at scale 3 = 180x180 points, within container.
        let within = TerminalLetterboxGeometry.clampPinnedSize(
            actualWidthPx: 540, actualHeightPx: 540, scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(within == CGSize(width: 180, height: 180))

        // refined exceeds container -> clamped.
        let clamped = TerminalLetterboxGeometry.clampPinnedSize(
            actualWidthPx: 3000, actualHeightPx: 3000, scale: 3,
            container: CGSize(width: 402, height: 700)
        )
        #expect(clamped == CGSize(width: 402, height: 700))
    }
}
