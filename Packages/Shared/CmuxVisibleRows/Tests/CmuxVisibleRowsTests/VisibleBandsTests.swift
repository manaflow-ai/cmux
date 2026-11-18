import CmuxVisibleRows
import Testing

/// The macOS vertical tab list's row layers (`VisibleBands`), with no UI, at 100 and 10,000 rows: the layers a 600 pt
/// viewport needs stay the rows in view and one each side, and a wheel step of one row reveals one layer, whatever the
/// length (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?").
@Suite struct VisibleBandsTests {
    static let bands = VisibleBands(pitch: 30, origin: 6)
    static let viewport = 600.0

    static func contentHeight(_ rows: Int) -> Double { 6 + Double(rows) * 30 + 6 }

    @Test(arguments: [100, 10_000])
    func aViewportNeedsItsRowsLayersAndOneEachSide(_ rows: Int) throws {
        let height = Self.contentHeight(rows)
        let offset = min(2_000, (height - Self.viewport) / 2)
        let shown = try #require(Self.bands.shown(minY: offset, maxY: offset + Self.viewport, contentHeight: height))
        #expect(shown.count <= Int(Self.viewport / 30) + 3, "\(shown.count) layers at n=\(rows)")
        // Every band in view is shown.
        #expect(shown.contains(Self.bands.band(offset)) && shown.contains(Self.bands.band(offset + Self.viewport - 0.5)))
    }

    @Test(arguments: [100, 10_000])
    func aOneRowWheelStepRevealsOneLayer(_ rows: Int) {
        let height = Self.contentHeight(rows)
        var offset = min(2_000, (height - Self.viewport) / 2)
        var before = Self.bands.shown(minY: offset, maxY: offset + Self.viewport, contentHeight: height)
        for step in [30.0, 30, -30, 12, 18] {
            offset += step
            let after = Self.bands.shown(minY: offset, maxY: offset + Self.viewport, contentHeight: height)
            let revealed = Range.total(VisibleBands.revealed(from: before, to: after))
            #expect(revealed <= 1, "a \(step) pt step revealed \(revealed) layers at n=\(rows)")
            before = after
        }
    }

    @Test func aRowsChangeTouchesItsLayerAlone() throws {
        let shown = try #require(Self.bands.shown(minY: 0, maxY: 600, contentHeight: Self.contentHeight(100)))
        // Row 4 spans 126..<154 (its band 4 is 126..<156): one layer; a row out of view touches none.
        #expect(Self.bands.touching(minY: 126, maxY: 154, in: shown) == 4...4)
        #expect(Self.bands.touching(minY: 2_406, maxY: 2_434, in: shown) == nil)
        #expect(Self.bands.span(4) == 126...156)
    }

    @Test func edges() {
        #expect(Self.bands.shown(minY: 0, maxY: 600, contentHeight: 0) == nil)
        #expect(Self.bands.shown(minY: 0, maxY: 0, contentHeight: 600) == nil)
        // A short list shows its bands only.
        #expect(Self.bands.shown(minY: 0, maxY: 600, contentHeight: Self.contentHeight(3)) == -1...3)
        #expect(VisibleBands.revealed(from: nil, to: 3...5) == [3..<6])
        #expect(VisibleBands.revealed(from: 3...5, to: nil).isEmpty)
    }
}
