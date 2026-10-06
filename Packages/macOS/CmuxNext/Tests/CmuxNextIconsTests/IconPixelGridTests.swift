import CoreGraphics
@testable import CmuxNextIcons
import Testing

/// Pack drawings land on whole device pixels: a 16 pt icon's strokes are
/// solid pixel columns at 1x and 2x, not half-inked pairs, and circles stay
/// round after snapping.
struct IconPixelGridTests {
    private struct Bitmap {
        let context: CGContext

        init(side: Int) throws {
            context = try #require(CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
        }

        init(image: CGImage) throws {
            try self.init(side: image.width)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }

        func alpha(x: Int, y: Int) throws -> UInt8 {
            let data = try #require(context.data)
            return data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + 3, as: UInt8.self)
        }

        /// Columns inked at `row`, with their alpha.
        func columns(row: Int) throws -> [Int: UInt8] {
            var inked: [Int: UInt8] = [:]
            for x in 0..<context.width {
                let a = try alpha(x: x, y: row)
                if a > 0 { inked[x] = a }
            }
            return inked
        }
    }

    private static let ink = CGColor(gray: 0, alpha: 1)

    /// The plus's vertical stroke, read away from its crossbar.
    private func stem(scale: CGFloat) throws -> [Int: UInt8] {
        let image = try #require(CGImage.icon(.actionAdd, size: 16, scale: scale, tint: Self.ink))
        let bitmap = try Bitmap(image: image)
        return try bitmap.columns(row: Int(5 * scale))
    }

    @Test func aSixteenPointStrokeIsOneSolidPixelAt1x() throws {
        let stem = try stem(scale: 1)
        #expect(stem.count == 1, "\(stem)")
        #expect(stem.values.allSatisfy { $0 == 255 }, "\(stem)")
    }

    @Test func aSixteenPointStrokeIsTwoSolidPixelsAt2x() throws {
        let stem = try stem(scale: 2)
        #expect(stem.count == 2, "\(stem)")
        #expect(stem.values.allSatisfy { $0 == 255 }, "\(stem)")
    }

    /// A view at a fractional origin still gets whole-pixel strokes.
    @Test func aFractionalOriginStillLandsOnPixels() throws {
        let layers = try #require(IconPack.bundled.drawing(for: .actionAdd)?.line)
        let bitmap = try Bitmap(side: 20)
        bitmap.context.drawIcon(layers, in: CGRect(x: 1.25, y: 1.25, width: 16, height: 16), ink: Self.ink)
        let stem = try bitmap.columns(row: 6)
        #expect(stem.count == 1, "\(stem)")
        #expect(stem.values.allSatisfy { $0 == 255 }, "\(stem)")
    }

    /// The account icon's ring snaps as a whole: its ink is as wide as it is
    /// tall and symmetric across the diagonal of its own box.
    @Test func circlesStayRound() throws {
        let ring = try #require(IconPack.bundled.drawing(for: .account)?.line.first)
        for side in [16, 32] {
            let bitmap = try Bitmap(side: side)
            bitmap.context.drawIcon([ring], in: CGRect(x: 0, y: 0, width: side, height: side), ink: Self.ink)
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<side {
                for x in 0..<side {
                    guard try bitmap.alpha(x: x, y: y) > 0 else { continue }
                    xs.append(x)
                    ys.append(y)
                }
            }
            let minX = try #require(xs.min()), maxX = try #require(xs.max())
            let minY = try #require(ys.min()), maxY = try #require(ys.max())
            #expect(maxX - minX == maxY - minY, "side \(side)")
            for dy in 0...(maxY - minY) {
                for dx in 0...(maxX - minX) {
                    let a = try bitmap.alpha(x: minX + dx, y: minY + dy)
                    let transposed = try bitmap.alpha(x: minX + dy, y: minY + dx)
                    #expect(abs(Int(a) - Int(transposed)) <= 2, "side \(side) at \(dx),\(dy)")
                }
            }
        }
    }

    /// Where the ring's top crosses its center column, the stroke is one
    /// solid pixel at 1x; the curve leaves at most a trace beside it.
    @Test func aRingEdgeIsSolidAt1x() throws {
        let ring = try #require(IconPack.bundled.drawing(for: .account)?.line.first)
        let bitmap = try Bitmap(side: 16)
        bitmap.context.drawIcon([ring], in: CGRect(x: 0, y: 0, width: 16, height: 16), ink: Self.ink)
        var column: [Int: UInt8] = [:]
        for y in 0..<8 {
            let a = try bitmap.alpha(x: 8, y: y)
            if a > 0 { column[y] = a }
        }
        let solid = column.filter { $0.value >= 250 }
        #expect(solid.count == 1, "\(column)")
        #expect(column.filter { $0.value < 250 }.values.allSatisfy { $0 <= 16 }, "\(column)")
    }
}
