import AppKit
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// The vertical tab list's rows on scrolling layers (`VerticalTabBands`): a band shows what the view's own drawing shows
/// there, upright; a scroll keeps the bands it had; a change out of view draws nothing until it scrolls in.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(2)))
struct VerticalTabBandsTests {
    @Test func aBandMatchesTheViewsOwnDrawing() async throws {
        let f = try await VerticalTabRows(rows: 40)
        defer { f.close() }
        let list = f.list
        // The selected row (a fill and a title) in band coordinates and as the view draws it whole (`draw(_:)`).
        let row = try #require(list.listLayout.row(ofTab: TabID("v0")))
        let index = list.bands.band(row.frame.minY)
        let band = try #require(list.bands.shown[index]?.contents, "no drawing for the first row's band")
        let bandImage = band as! CGImage // swiftlint:disable:this force_cast
        let rect = list.viewRect(list.bands.rect(index))
        let rep = try #require(list.bitmapImageRepForCachingDisplay(in: rect))
        list.cacheDisplay(in: rect, to: rep)
        let viewImage = try #require(rep.cgImage)
        let upright = try Self.difference(bandImage, viewImage, flipping: false)
        let flipped = try Self.difference(bandImage, viewImage, flipping: true)
        #expect(upright < 0.02 && upright < flipped / 2, "band vs view: \(upright) upright, \(flipped) flipped")
    }

    @Test func aScrollKeepsItsBandsAndAFarChangeShowsWhenItScrollsIn() async throws {
        let f = try await VerticalTabRows(rows: 200)
        defer { f.close() }
        let list = f.list, model = f.model
        let pitch = list.metrics.rowHeight + list.metrics.rowSpacing
        let kept = list.bands.shown.filter { $0.key > list.bands.band(list.scrollOffset) + 1 }
        f.scroll(by: pitch)
        for (index, layer) in kept where list.bands.shown[index] != nil {
            #expect(list.bands.shown[index] === layer && layer.contents != nil, "band \(index) changed on a scroll")
        }
        #expect(list.rowViewsAlive <= f.viewportRows + 2 + VerticalTabBands.parkLimit)
        // A tab far below changes: nothing draws; scrolled to, its row draws with the new title.
        _ = list.listWork.take()
        model.tabs[150].title = "Far away"
        list.modelChanged()
        VerticalTabRows.drawFrame(f.window)
        #expect(list.listWork.take().rowsConfigured == 0)
        let far = try #require(list.listLayout.row(ofTab: TabID("v150")))
        f.scroll(by: far.frame.minY - list.scrollOffset - 100)
        #expect(list.bands.shown[list.bands.band(far.frame.minY)]?.contents != nil)
        #expect(list.listLayout.item(far)?.title == "Far away")
    }

    /// Mean per-channel difference (0...1) of `a` and `b` drawn at `b`'s size, `a` upside down when `flipping`.
    static func difference(_ a: CGImage, _ b: CGImage, flipping: Bool) throws -> Double {
        let w = b.width, h = b.height
        func pixels(_ image: CGImage, flip: Bool) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            data.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                if flip {
                    ctx.translateBy(x: 0, y: CGFloat(h))
                    ctx.scaleBy(x: 1, y: -1)
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return data
        }
        let pa = try pixels(a, flip: flipping), pb = try pixels(b, flip: false)
        let total = zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(pa.count * 255)
    }
}
