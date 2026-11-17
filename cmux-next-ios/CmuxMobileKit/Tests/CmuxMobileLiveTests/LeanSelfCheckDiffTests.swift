import CoreGraphics
@testable import CmuxMobileLive
import Foundation
import Testing

/// The lean terminal self-check's pixel diff (`LeanSelfCheckDiff`): a rendering shifted by one
/// cell fails the simulator pixel matrix's thresholds, which the Mac's host applies to these
/// counts (cmux-mobile-host `self_check.rs`: at most 0.05% of the grid's pixels, 0.1% of each
/// band), and the same rendering passes; the cursor's cell never counts.
@Suite struct LeanSelfCheckDiffTests {
    /// The host's thresholds (`self_check.rs` `GRID_LIMIT`, `BAND_LIMIT`).
    static let gridLimit = 0.0005
    static let bandLimit = 0.001

    // A 40x8 grid of 6x12 px cells at 1 px per point, drawn at (10, 20) of a 260x120 rect.
    static let cell = CGSize(width: 6, height: 12)
    static let grid = CGRect(x: 10, y: 20, width: 240, height: 96)
    static let rect = CGRect(x: 0, y: 0, width: 260, height: 120)

    /// A terminal-like frame: a glyph block in most cells (a header row, text, both edge columns),
    /// shifted `dx` px; `cursor`: a block in that cell too.
    static func frame(dx: Int = 0, cursor: (column: Int, row: Int)? = nil) -> CGImage {
        let (width, height) = (Int(rect.width), Int(rect.height))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        // Core Graphics' origin is at the bottom: flip, so rows count from the top as on screen.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for row in 0..<8 {
            for column in 0..<40 where (row * 7 + column * 3) % 5 != 0 || column == 0 || column == 39 {
                let x = grid.minX + CGFloat(column) * cell.width + 1 + CGFloat(dx)
                let y = grid.minY + CGFloat(row) * cell.height + 2
                context.fill(CGRect(x: x, y: y, width: 3, height: 8))
            }
        }
        if let cursor {
            context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: grid.minX + CGFloat(cursor.column) * cell.width, y: grid.minY + CGFloat(cursor.row) * cell.height,
                                width: cell.width, height: cell.height))
        }
        return context.makeImage()!
    }

    static func cursorRect(column: Int, row: Int) -> CGRect {
        CGRect(x: grid.minX + CGFloat(column) * cell.width, y: grid.minY + CGFloat(row) * cell.height,
               width: cell.width, height: cell.height)
    }

    /// The host's verdict on a diff's counts: the reasons it fails (none: it passes).
    static func failures(_ diff: LeanSelfCheckDiff) -> [String] {
        var why: [String] = []
        if diff.compared == 0 { why.append("no pixels compared") }
        if Double(diff.differing) / Double(max(diff.compared, 1)) > gridLimit {
            why.append("grid: \(diff.differing) of \(diff.compared)")
        }
        for band in diff.bands where band.compared > 0 && Double(band.differing) / Double(band.compared) > bandLimit {
            why.append("\(band.name): \(band.differing) of \(band.compared)")
        }
        return why
    }

    @Test func theSameRenderingPasses() throws {
        let diff = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(), rect: Self.rect, grid: Self.grid,
                                                  cell: Self.cell, cursors: []))
        #expect(diff.compared == 240 * 96)
        #expect(diff.differing == 0)
        #expect(Self.failures(diff).isEmpty)
        #expect(diff.bands.map(\.compared) == [240 * 36, 6 * 96, 6 * 96])
    }

    @Test func aRenderingShiftedByOneCellFails() throws {
        let diff = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(dx: Int(Self.cell.width)), rect: Self.rect,
                                                  grid: Self.grid, cell: Self.cell, cursors: []))
        let why = Self.failures(diff)
        #expect(why.contains { $0.hasPrefix("grid:") }, "\(why)")
        #expect(why.contains { $0.hasPrefix("header:") }, "\(why)")
        #expect(why.contains { $0.hasPrefix("firstColumn:") }, "\(why)")
        #expect(why.contains { $0.hasPrefix("lastColumn:") }, "\(why)")
    }

    @Test func aRenderingOnePixelOffFails() throws {
        let diff = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(dx: 1), rect: Self.rect,
                                                  grid: Self.grid, cell: Self.cell, cursors: []))
        #expect(!Self.failures(diff).isEmpty)
    }

    @Test func theCursorCellIsLeftOut() throws {
        let cursor = Self.cursorRect(column: 39, row: 7)
        let diff = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(cursor: (39, 7)), rect: Self.rect,
                                                  grid: Self.grid, cell: Self.cell, cursors: [cursor]))
        #expect(diff.differing == 0)
        #expect(Self.failures(diff).isEmpty)
        // Without the cursor's cell left out, the same frames differ in the last column.
        let counted = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(cursor: (39, 7)), rect: Self.rect,
                                                     grid: Self.grid, cell: Self.cell, cursors: []))
        #expect(Self.failures(counted).contains { $0.hasPrefix("lastColumn:") })
    }

    @Test func framesOfDifferentSizesAreNotCompared() {
        let small = Self.frame().cropping(to: CGRect(x: 0, y: 0, width: 100, height: 100))!
        #expect(LeanSelfCheckDiff(pty: Self.frame(), lean: small, rect: Self.rect, grid: Self.grid, cell: Self.cell, cursors: []) == nil)
    }

    @Test func theDiffImageIsAPNG() throws {
        let diff = try #require(LeanSelfCheckDiff(pty: Self.frame(), lean: Self.frame(dx: 6), rect: Self.rect, grid: Self.grid,
                                                  cell: Self.cell, cursors: []))
        let png = try #require(LeanSelfCheckDiff.png(diff.image))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(diff.image.width == 260 && diff.image.height == 120)
    }
}
