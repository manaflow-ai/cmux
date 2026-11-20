import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// A Before|After × Light|Dark table (the user, 2026-11-05, msg 23164: "before/after ui should make all of the
/// things visible better, instead of just being gallery view"): the card shows each pair large, side by side
/// across its full width, and a click opens the pair on the viewer's slider with Light | Dark as a switch.
@Suite(.serialized) @MainActor struct HomeCompareLayoutTests {
    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    static func loadedTable() async throws -> (HomeTable, CustomPart) {
        let f = HomePictureViewerTests.folder()
        try HomePictureViewerTests.shots(f)
        let pictures = HomeTablePictures()
        for name in ["bl", "al", "bd", "ad"] { _ = await pictures.prepare(f.appendingPathComponent("\(name).png").path) }
        let part = try HomePictureViewerTests.card(HomePictureViewerTests.beforeAfter(f), media: { pictures.asset($0) })
        return (try #require(HomeTableRowProvider.payload(part)).table, part)
    }

    @Test func aBeforeAfterTableDrawsEachPairLargeAcrossTheCardsWidth() async throws {
        let (table, _) = try await Self.loadedTable()
        let width: CGFloat = 1100
        let pairs = HomeTableGrid(table, available: width)
        let grid = HomeTableGrid(table, available: width, style: .grid)
        #expect(pairs.compare != nil)
        #expect(grid.compare == nil)
        let rects = pairs.pictureRects(at: .zero)
        #expect(rects.count == 4)
        // Each row's two pictures sit side by side and together span the card's inside.
        let light = rects.prefix(2).map(\.rect)
        #expect(light[0].minY == light[1].minY)
        #expect(light[0].maxX < light[1].minX)
        #expect(light[0].minX >= HomeTableGrid.pad && light[1].maxX <= width - HomeTableGrid.pad)
        #expect(light[0].width + light[1].width >= width - 2 * HomeTableGrid.pad - 2 * HomeCompareLayout.pictureGap)
        // Dark comes below Light, and both are far larger than the grid's thumbnails.
        #expect(rects[2].rect.minY > light[0].maxY)
        let small = grid.pictureRects(at: .zero)
        #expect(light[0].width > 1.5 * small[0].rect.width)
        // The card is as tall as its rows: no dead space under the last picture.
        #expect(pairs.height - rects[3].rect.maxY <= HomeTableGrid.pad + 1)
    }

    @Test func aTableThatIsNotAComparisonKeepsTheGrid() throws {
        let words = HomeTable(header: ["", "Before", "After"], alignments: [.leading, .leading, .leading],
                              rows: [["Light", "old", "new"]], pictures: nil, loading: nil)
        #expect(!HomeCompareLayout.matches(words))
        #expect(HomeTableGrid(words, available: 700).compare == nil)
        let named = HomeTable(header: ["Theme", "Before", "After"], alignments: [.leading, .leading, .leading],
                              rows: [["Light", "![a](a.png)", "![b](b.png)"]], pictures: nil, loading: nil)
        #expect(!HomeCompareLayout.matches(named))
    }

    @Test func aClickOpensThePairOnTheSliderAndUpAndDownSwitchLightAndDark() async throws {
        let (table, part) = try await Self.loadedTable()
        let rects = HomeTableGrid(table, available: 900).pictureRects(at: .zero)
        let lightAfter = try #require(rects.first { $0.source.hasSuffix("al.png") })
        #expect(HomeTableRowProvider.picture(part, at: CGPoint(x: lightAfter.rect.midX, y: lightAfter.rect.midY), width: 900) == lightAfter.source)
        let gallery = try #require(HomePictureGallery(table: table, opening: lightAfter.source))
        #expect(gallery.opensComparing)
        #expect(gallery.labeledRows == [0, 1])
        #expect(gallery.rowLabels == [0: "Light", 1: "Dark"])
        #expect(gallery.moved(toRow: 1).index == 3)
        let picture = try HomePictureViewerTests.image(width: 400, height: 250)
        let viewer = HomePictureViewer(frame: CGRect(x: 0, y: 0, width: 900, height: 700), gallery: gallery, load: { _ in picture })
        viewer.reduceMotion = { true }
        await viewer.loaded()
        #expect(viewer.isComparing)
        #expect(viewer.handle(.down))
        #expect(viewer.gallery.index == 3)
        #expect(viewer.gallery.current?.title == "Dark · After")
        #expect(!viewer.handle(.down))
        #expect(viewer.handle(.up))
        #expect(viewer.gallery.index == 1)
        await viewer.loaded()
        viewer.close()
        #expect(viewer.isClosed)
    }

    /// The open grows out of the thumbnail (matched geometry): with Reduce Motion it is at once and nothing is
    /// left over the pane; a closed viewer takes no clicks.
    @Test func reduceMotionOpensAndClosesAtOnce() async throws {
        let picture = try HomePictureViewerTests.image(width: 400, height: 250)
        let gallery = HomePictureGallery(items: [.init(source: "s", url: URL(fileURLWithPath: "/tmp/s.png"), title: "Shot", row: 0, column: 0)], index: 0)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let viewer = HomePictureViewer(frame: host.bounds, gallery: gallery, load: { _ in picture })
        viewer.reduceMotion = { true }
        host.addSubview(viewer)
        viewer.present(from: CGRect(x: 40, y: 60, width: 200, height: 125), thumbnail: picture)
        #expect(viewer.layer?.sublayers?.contains { $0.zPosition == 10 } != true)
        #expect(viewer.subviews.allSatisfy { $0.alphaValue == 1 })
        await viewer.loaded()
        viewer.close()
        #expect(viewer.superview == nil)
        #expect(viewer.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }
}
