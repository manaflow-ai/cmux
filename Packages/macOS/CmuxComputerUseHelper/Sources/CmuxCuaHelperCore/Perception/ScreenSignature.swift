// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// A grey copy of a delivered screenshot at half size, compared tile by tile
/// with the last screenshot the agent saw of the same window. Two equal
/// screenshots give equal bytes (the same image drawn the same way), so
/// "unchanged" never hides a change a tile can see. The idea follows
/// `display_still`'s thumbnail signature (scripts/cmux-cua-display-still.patch),
/// at a resolution that sees one typed character instead of a 32x20 mean.
struct ScreenSignature: Equatable, Sendable {
    /// Screenshot pixels per signature cell, each way.
    static let cell = 2
    /// Signature cells per tile, each way: a tile covers 64x64 screenshot pixels.
    static let tileCells = 32
    /// A tile is dirty when any cell in it moved by at least this much (of 255).
    static let threshold: UInt8 = 24

    /// The delivered screenshot's size in pixels.
    let width: Int
    let height: Int
    /// Signature size in cells.
    let columns: Int
    let rows: Int
    let grey: [UInt8]

    init(width: Int, height: Int, columns: Int, rows: Int, grey: [UInt8]) {
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.grey = grey
    }

    /// Draws `image` into a grey bitmap of half its size.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let columns = max(1, width / Self.cell)
        let rows = max(1, height / Self.cell)
        var grey = [UInt8](repeating: 0, count: columns * rows)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: columns,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, columns: columns, rows: rows, grey: grey)
    }

    /// What changed against `previous`: nil when the two cannot be compared
    /// (another size), else the dirty rectangle in screenshot pixels (nil
    /// inside when nothing changed).
    func change(since previous: ScreenSignature) -> Change? {
        guard previous.width == width, previous.height == height,
              previous.columns == columns, previous.rows == rows else { return nil }
        let tile = Self.tileCells
        var minColumn = Int.max, minRow = Int.max, maxColumn = -1, maxRow = -1
        var dirtyTiles = 0
        var tileRow = 0
        while tileRow * tile < rows {
            var tileColumn = 0
            while tileColumn * tile < columns {
                if tileDiffers(previous, tileColumn: tileColumn, tileRow: tileRow) {
                    dirtyTiles += 1
                    minColumn = min(minColumn, tileColumn)
                    maxColumn = max(maxColumn, tileColumn)
                    minRow = min(minRow, tileRow)
                    maxRow = max(maxRow, tileRow)
                }
                tileColumn += 1
            }
            tileRow += 1
        }
        guard dirtyTiles > 0 else { return Change(rect: nil, dirtyTiles: 0) }
        let pixelsPerTile = tile * Self.cell
        let x = minColumn * pixelsPerTile
        let y = minRow * pixelsPerTile
        let rect = PixelRect(x: x, y: y,
                             width: min(width, (maxColumn + 1) * pixelsPerTile) - x,
                             height: min(height, (maxRow + 1) * pixelsPerTile) - y)
        return Change(rect: rect, dirtyTiles: dirtyTiles)
    }

    private func tileDiffers(_ previous: ScreenSignature, tileColumn: Int, tileRow: Int) -> Bool {
        let tile = Self.tileCells
        let rowEnd = min(rows, (tileRow + 1) * tile)
        let columnEnd = min(columns, (tileColumn + 1) * tile)
        for row in (tileRow * tile)..<rowEnd {
            let base = row * columns
            for column in (tileColumn * tile)..<columnEnd {
                let a = grey[base + column], b = previous.grey[base + column]
                if (a > b ? a - b : b - a) >= Self.threshold { return true }
            }
        }
        return false
    }

    struct Change: Equatable {
        /// The bounding box of the dirty tiles; nil when nothing changed.
        let rect: PixelRect?
        let dirtyTiles: Int
    }
}

/// A rectangle in screenshot pixels, top-left origin.
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var area: Int { width * height }
    var json: [String: Int] { ["x": x, "y": y, "w": width, "h": height] }
}
