import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// A Before|After × Light|Dark table (the user, 2026-11-05, msg 23164: "top left has itnersect"): the header
/// row's rule ran through the empty corner cell, so the rule and the row labels' column crossed in the top
/// left. A table whose first header cell is empty draws no rule through that corner.
@Suite(.serialized) struct HomeTableCornerTests {
    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    /// A text-only matrix with an empty corner: the grid layout, which draws the header rule.
    static let matrix = HomeTable(header: ["", "Before", "After"], alignments: [.leading, .leading, .leading],
                                  rows: [["Light", "old", "new"], ["Dark", "old", "new"]], pictures: nil, loading: nil)

    /// `grid` drawn into a y-down bitmap of `scale` pixels per point.
    static func render(_ grid: HomeTableGrid, scale: CGFloat = 2) throws -> (CGContext, UnsafeMutablePointer<UInt32>) {
        let w = Int(grid.cardWidth * scale), h = Int(grid.height * scale)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        grid.draw(ctx, at: .zero)
        let data = try #require(ctx.data).bindMemory(to: UInt32.self, capacity: w * h)
        return (ctx, data)
    }

    @Test func theHeaderRuleDoesNotCrossAnEmptyCornerCell() throws {
        let grid = HomeTableGrid(Self.matrix, available: 700)
        let scale: CGFloat = 2
        let (ctx, pixels) = try Self.render(grid, scale: scale)
        let width = ctx.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> UInt32 { pixels[Int((y * scale).rounded(.down)) * width + Int((x * scale).rounded(.down))] }
        let ruleY = HomeTableGrid.pad + grid.heights[0]
        let cornerX = HomeTableGrid.pad + grid.widths[0] / 2
        let bodyX = HomeTableGrid.pad + grid.widths[0] + grid.widths[1] / 2
        // Under the header names the rule draws (the row differs from the card just above it) ...
        #expect(pixel(bodyX, ruleY) != pixel(bodyX, ruleY - 3))
        // ... and in the empty corner it does not: the corner is the card's plain fill.
        #expect(pixel(cornerX, ruleY) == pixel(cornerX, ruleY - 3))
    }

    @Test func aTableWithAHeaderInItsFirstCellKeepsItsFullRule() throws {
        var table = Self.matrix
        table.header[0] = "Theme"
        let grid = HomeTableGrid(table, available: 700)
        let scale: CGFloat = 2
        let (ctx, pixels) = try Self.render(grid, scale: scale)
        let width = ctx.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> UInt32 { pixels[Int((y * scale).rounded(.down)) * width + Int((x * scale).rounded(.down))] }
        let ruleY = HomeTableGrid.pad + grid.heights[0]
        let firstX = HomeTableGrid.pad + grid.widths[0] / 2
        #expect(pixel(firstX, ruleY) != pixel(firstX, ruleY - 3))
    }
}
