import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Four-edge docks and frame orientation (plans/cmux-next/layout-model.md,
/// F1 to F4). Default style: gap 6, no pane padding, 1000 x 600 viewport,
/// scale 2. Left and right alone are pinned by StickyColumnGeometryTests.
@Suite struct FrameDockGeometryTests {
    let viewport = CGSize(width: 1000, height: 600)

    private func layout(left: StickyMode? = .docked, band: StickyEdge = .bottom, bandMode: StickyMode = .docked) -> ScreenLayout {
        var columns: [LayoutColumn] = []
        if let left { columns.append(LayoutColumn(id: "l", width: 0.25, root: .leaf("pl"), sticky: StickyColumn(edge: .left, mode: left))) }
        columns.append(LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")))
        columns.append(LayoutColumn(id: "b", width: 0.5, root: .leaf("pb")))
        columns.append(LayoutColumn(id: "d", width: 0.3, root: .leaf("pd"), sticky: StickyColumn(edge: band, mode: bandMode)))
        return .columns(columns)
    }

    private func geometry(_ layout: ScreenLayout, _ orientation: FrameOrientation = .columnMajor) -> ScreenGeometry {
        var style = LayoutStyle()
        style.frameOrientation = orientation
        return ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    @Test func columnMajorSideDockRunsFullHeightAndTheBandSitsBetween() {
        let g = geometry(layout())
        // Left: (1000 - 6) * 0.25 - 6 = 242.5 wide at x 6 (scale 2 keeps half points). Band: (600 - 6) * 0.3 - 6 = 172.2 -> 172 high.
        #expect(g.panes["pl"] == CGRect(x: 6, y: 0, width: 242.5, height: 600))
        #expect(g.panes["pd"] == CGRect(x: 254.5, y: 428, width: 739.5, height: 172))
        #expect(g.stripMinY == 0 && g.stripHeight == 422)
        #expect(g.panes["pa"]?.height == 422)
        #expect(g.fixedPanes == ["pl", "pd"])
        #expect(g.columnOrder == ["a", "b"])
        #expect(g.uncoveredMaxY == 422)
        // The strip scrolls only horizontally; the band never moves.
        #expect(g.sticky.first { $0.column == "d" }?.cover == CGRect(x: 248.5, y: 422, width: 751.5, height: 178))
    }

    @Test func rowMajorBandRunsFullWidthAndTheSideDockSitsBetween() {
        let g = geometry(layout(), .rowMajor)
        #expect(g.panes["pd"] == CGRect(x: 6, y: 428, width: 988, height: 172))
        #expect(g.panes["pl"] == CGRect(x: 6, y: 0, width: 242.5, height: 422))
        // Extents are the same in both orientations; only lengths change.
        #expect(g.stripHeight == 422 && g.stripMinX == 248.5)
    }

    @Test func topBandMovesTheStripDown() {
        let g = geometry(layout(band: .top))
        #expect(g.panes["pd"]?.minY == 0)
        #expect(g.stripMinY == 178 && g.stripHeight == 422)
        #expect(g.panes["pa"]?.minY == 178)
        #expect(g.gapZones.allSatisfy { $0.frame.minY == 178 && $0.frame.height == 422 })
    }

    @Test func overlayBandInsetsTheStripAndKeepsItsGlassRim() {
        let g = geometry(layout(left: nil, band: .bottom, bandMode: .overlay))
        // At rest nothing is covered: the strip ends above the band and its gap.
        #expect(g.stripHeight == 422)
        #expect(g.uncoveredMaxY == 425)
        #expect(g.clipMaxY == 600)
        let band = try! #require(g.sticky.first { $0.column == "d" })
        #expect(band.glass == band.frame.insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: viewport)))
    }

    @Test func bandsCapAtAThirdEachWithBothAndAHalfAlone() {
        let tall: ScreenLayout = .columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")),
            LayoutColumn(id: "t", width: 0.9, root: .leaf("pt"), sticky: StickyColumn(edge: .top, mode: .docked)),
            LayoutColumn(id: "u", width: 0.9, root: .leaf("pu"), sticky: StickyColumn(edge: .bottom, mode: .docked)),
        ])
        let both = geometry(tall)
        #expect(both.panes["pt"]?.height == 200 && both.panes["pu"]?.height == 200)
        let one = geometry(.columns(Array(tall.columns.prefix(2))))
        #expect(one.panes["pt"]?.height == 300)
    }

    @Test func aFloatingCornerOwnerNeverCoversTheOtherDock() {
        // Row-major, floating top band: the left dock still starts below it.
        let rowMajor = geometry(layout(band: .top, bandMode: .overlay), .rowMajor)
        #expect(rowMajor.panes["pl"]?.minY == 178)
        // Column-major, floating left dock: the band still starts past it.
        let columnMajor = geometry(layout(left: .overlay), .columnMajor)
        #expect(columnMajor.panes["pd"]?.minX == 254.5)
    }

    @Test func cornersBelongToSideDocksColumnMajorAndToBandsRowMajor() {
        #expect(StickyStripGeometry.ownsCorners(.left, orientation: .columnMajor))
        #expect(!StickyStripGeometry.ownsCorners(.bottom, orientation: .columnMajor))
        #expect(StickyStripGeometry.ownsCorners(.top, orientation: .rowMajor))
        #expect(!StickyStripGeometry.ownsCorners(.right, orientation: .rowMajor))
    }

    @Test func aScreenOfOnlyDocksShowsThemInTheStrip() {
        let only: ScreenLayout = .columns([LayoutColumn(id: "t", width: 0.3, root: .leaf("pt"), sticky: StickyColumn(edge: .top, mode: .docked))])
        let g = geometry(only)
        #expect(g.sticky.isEmpty && g.columnOrder == ["t"])
    }
}
