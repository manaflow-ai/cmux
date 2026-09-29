import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

/// A 54×44 phone: 390×600 pt viewport, 7.2×13.6 pt cells.
@Suite struct TerminalGridFitTests {
    private let container = CGSize(width: 390, height: 600)
    private let cell = CGSize(width: 7.2, height: 13.6)

    private func mode(cols: Int, rows: Int) -> TerminalGridFitMode {
        TerminalGridFit.mode(
            effectiveColumns: cols,
            effectiveRows: rows,
            measuredColumns: 54,
            measuredRows: 44,
            gridPointSize: CGSize(width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height),
            container: container
        )
    }

    @Test func noSharedGridFillsTheContainer() {
        #expect(TerminalGridFit.mode(
            effectiveColumns: nil, effectiveRows: nil, measuredColumns: 54, measuredRows: 44,
            gridPointSize: .zero, container: container
        ) == .natural)
    }

    @Test func matchingGridFillsTheContainer() {
        #expect(mode(cols: 54, rows: 44) == .natural)
    }

    @Test func smallerGridLetterboxes() {
        #expect(mode(cols: 40, rows: 30) == .letterbox)
        #expect(mode(cols: 54, rows: 30) == .letterbox)
    }

    @Test func widerGridScales() {
        #expect(mode(cols: 175, rows: 30) == .scaledToFit)
    }

    @Test func tallerGridScales() {
        #expect(mode(cols: 54, rows: 78) == .scaledToFit)
    }

    @Test func largerGridOnBothAxesScales() {
        #expect(mode(cols: 175, rows: 78) == .scaledToFit)
    }

    @Test func unmeasuredSurfaceFillsTheContainer() {
        #expect(TerminalGridFit.mode(
            effectiveColumns: 175, effectiveRows: 78, measuredColumns: 0, measuredRows: 0,
            gridPointSize: CGSize(width: 1260, height: 1060.8), container: container
        ) == .natural)
    }
}

/// libghostty's layout: padding comes off first, then whole cells.
@Suite struct TerminalGridFitRequestedPixelSizeTests {
    private func ghosttyGrid(widthPx: Int, heightPx: Int, padding: Int, cell: (Int, Int)) -> (Int, Int) {
        ((widthPx - padding) / cell.0, (heightPx - padding) / cell.1)
    }

    private func natural(widthPx: Int, heightPx: Int, padding: Int, cell: (Int, Int)) -> TerminalNaturalGridMeasurement {
        let grid = ghosttyGrid(widthPx: widthPx, heightPx: heightPx, padding: padding, cell: cell)
        return TerminalNaturalGridMeasurement(
            columns: grid.0, rows: grid.1, widthPx: widthPx, heightPx: heightPx,
            cellWidthPx: cell.0, cellHeightPx: cell.1
        )
    }

    /// The iPhone 17 surface from the e2e run: 1206×1641 px, 18×35 px cells,
    /// 66×46 natural. A 120×40 fixed grid laid out 121 columns, so the apply
    /// fence rejected every render-grid replay and the phone froze.
    @Test(arguments: [0, 4, 10, 14])
    func oversizeGridLandsOnTheExactGrid(padding: Int) {
        let measured = natural(widthPx: 1206, heightPx: 1641, padding: padding, cell: (18, 35))
        for (cols, rows) in [(120, 40), (175, 78), (105, 45), (66, 46), (200, 60)] {
            let size = TerminalGridFit.requestedPixelSize(columns: cols, rows: rows, natural: measured)
            let laidOut = ghosttyGrid(widthPx: size.width, heightPx: size.height, padding: padding, cell: (18, 35))
            #expect(laidOut.0 == cols, "\(cols)x\(rows) padding \(padding)")
            #expect(laidOut.1 == rows, "\(cols)x\(rows) padding \(padding)")
        }
    }

    @Test func smallerGridLandsOnTheExactGrid() {
        let measured = natural(widthPx: 1206, heightPx: 1641, padding: 10, cell: (18, 35))
        let size = TerminalGridFit.requestedPixelSize(columns: 40, rows: 20, natural: measured)
        let laidOut = ghosttyGrid(widthPx: size.width, heightPx: size.height, padding: 10, cell: (18, 35))
        #expect(laidOut.0 == 40)
        #expect(laidOut.1 == 20)
    }
}

@Suite struct TerminalScaledGridLayoutTests {
    private let viewport = CGRect(x: 0, y: 100, width: 390, height: 600)

    /// 175×78 on the 54×44 phone: the whole grid shows, scaled to the width
    /// and top-pinned, with slack below it.
    @Test func largerOnBothAxesFitsTheWidth() {
        let layout = TerminalScaledGridLayout(gridSize: CGSize(width: 1260, height: 1060.8), viewport: viewport)
        let scale = 390.0 / 1260.0
        #expect(abs(layout.fitScale - scale) < 1e-9)
        #expect(layout.displayScale == layout.fitScale)
        #expect(layout.isScaled)
        #expect(abs(layout.displayRect.width - 390) < 1e-9)
        #expect(abs(layout.displayRect.height - 1060.8 * scale) < 1e-9)
        #expect(layout.displayRect.minX == 0)
        #expect(layout.displayRect.minY == viewport.minY)
        #expect(layout.displayRect.height < viewport.height)
        #expect(layout.offset == .zero)
    }

    @Test func widerOnlyFitsTheWidthAndKeepsAspect() {
        let grid = CGSize(width: 1260, height: 408)
        let layout = TerminalScaledGridLayout(gridSize: grid, viewport: viewport)
        #expect(abs(layout.displayRect.width - 390) < 1e-9)
        #expect(abs(layout.displayRect.width / layout.displayRect.height - grid.width / grid.height) < 1e-9)
        #expect(layout.displayRect.minY == viewport.minY)
    }

    /// Taller only: the width already fits, so nothing shrinks. The grid
    /// stays 1:1, bottom-pinned, and the top is reachable by panning.
    @Test func tallerOnlyKeepsOneToOneAndPansToTheTop() {
        let grid = CGSize(width: 388.8, height: 1060.8)
        let layout = TerminalScaledGridLayout(gridSize: grid, viewport: viewport)
        #expect(layout.displayScale == 1)
        #expect(!layout.isScaled)
        #expect(layout.maximumMagnification == 1)
        #expect(layout.displayRect.maxY == viewport.maxY)
        #expect(layout.displayRect.minY < viewport.minY)

        let top = layout.panned(by: CGPoint(x: 0, y: 10_000))
        #expect(top.displayRect.minY == viewport.minY)
        #expect(abs(top.offset.y - (1060.8 - 600)) < 1e-9)
        // Horizontal panning has nothing to reveal.
        #expect(top.panned(by: CGPoint(x: -50, y: 0)).offset.x == 0)
    }

    @Test func gridThatFitsIsNotEnlarged() {
        let layout = TerminalScaledGridLayout(gridSize: CGSize(width: 300, height: 400), viewport: viewport)
        #expect(layout.displayScale == 1)
        #expect(layout.displayRect == CGRect(x: 0, y: 100, width: 300, height: 400))
    }

    @Test func magnificationIsClampedBetweenFitAndOneToOne() {
        let base = TerminalScaledGridLayout(gridSize: CGSize(width: 1260, height: 1060.8), viewport: viewport)
        #expect(abs(base.maximumMagnification - 1260.0 / 390.0) < 1e-9)
        let out = TerminalScaledGridLayout(
            gridSize: base.gridSize, viewport: viewport, magnification: 0.2
        )
        #expect(out.magnification == 1)
        let far = TerminalScaledGridLayout(
            gridSize: base.gridSize, viewport: viewport, magnification: 50
        )
        #expect(abs(far.displayScale - 1) < 1e-9)
    }

    /// Pinch zoom keeps the grid point under the fingers fixed, then pans
    /// within the magnified grid without leaving a gap.
    @Test func zoomKeepsTheFocusPointAndPanClamps() {
        let base = TerminalScaledGridLayout(gridSize: CGSize(width: 1260, height: 1060.8), viewport: viewport)
        let focus = CGPoint(x: 200, y: 600)
        let gridX = (focus.x - base.displayRect.minX) / base.displayScale
        let gridY = (focus.y - base.displayRect.minY) / base.displayScale

        let zoomed = base.zoomed(to: 3, about: focus)
        #expect(zoomed.magnification == 3)
        #expect(abs(zoomed.displayRect.minX + gridX * zoomed.displayScale - focus.x) < 1e-6)
        #expect(abs(zoomed.displayRect.minY + gridY * zoomed.displayScale - focus.y) < 1e-6)
        #expect(zoomed.displayRect.minX <= viewport.minX)
        #expect(zoomed.displayRect.maxX >= viewport.maxX)

        let right = zoomed.panned(by: CGPoint(x: -10_000, y: 0))
        #expect(abs(right.displayRect.maxX - viewport.maxX) < 1e-6)
        let left = zoomed.panned(by: CGPoint(x: 10_000, y: 0))
        #expect(left.displayRect.minX == viewport.minX)
        let bottom = zoomed.panned(by: CGPoint(x: 0, y: -10_000))
        #expect(abs(bottom.displayRect.maxY - viewport.maxY) < 1e-6)
        let top = zoomed.panned(by: CGPoint(x: 0, y: 10_000))
        #expect(abs(top.displayRect.minY - viewport.minY) < 1e-6)

        // Zooming back out re-fits the whole width and drops the pan.
        let refit = top.zoomed(to: 1, about: focus)
        #expect(refit.magnification == 1)
        #expect(refit.displayRect.minX == viewport.minX)
        #expect(refit.displayRect.minY == viewport.minY)
    }

    /// A viewport change (keyboard, rotation) keeps the magnification and
    /// re-clamps the pan.
    @Test func viewportChangeReclampsThePan() {
        let zoomed = TerminalScaledGridLayout(
            gridSize: CGSize(width: 1260, height: 1060.8), viewport: viewport, magnification: 3,
            offset: CGPoint(x: 5_000, y: 5_000)
        )
        let shorter = TerminalScaledGridLayout(
            gridSize: zoomed.gridSize,
            viewport: CGRect(x: 0, y: 100, width: 390, height: 300),
            magnification: zoomed.magnification,
            offset: CGPoint(x: 5_000, y: 5_000)
        )
        #expect(shorter.magnification == 3)
        #expect(abs(shorter.displayRect.minY - 100) < 1e-6)
        #expect(abs(shorter.displayRect.maxX - 390) < 1e-6)
    }

    /// A scaled grid shorter than the viewport stays top-pinned at every
    /// magnification that leaves it shorter; a pan cannot move it off the top.
    @Test func shortScaledGridStaysTopPinned() {
        let layout = TerminalScaledGridLayout(
            gridSize: CGSize(width: 1260, height: 408), viewport: viewport, magnification: 1.2,
            offset: CGPoint(x: 0, y: 40)
        )
        #expect(layout.displayRect.height < viewport.height)
        #expect(layout.displayRect.minY == viewport.minY)
        #expect(layout.offset.y == 0)
    }
}
