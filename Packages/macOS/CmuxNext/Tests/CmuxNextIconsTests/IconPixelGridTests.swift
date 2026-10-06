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

    /// The account icon's ring fits as a whole, checked on its geometry
    /// (CoreGraphics antialiasing is not symmetric under transposition): a
    /// square box, a whole-pixel diameter, and a 1x stroke centered on pixel
    /// centers or a 2x stroke on pixel edges.
    @Test(arguments: [1, 2] as [CGFloat])
    func circlesStayRound(scale: CGFloat) throws {
        let ring = try #require(IconPack.bundled.drawing(for: .account)?.line.first)
        let toDevice = CGAffineTransform(scaleX: 16 * scale / 24, y: -16 * scale / 24)
            .concatenating(CGAffineTransform(translationX: 1.25, y: 16 * scale))
        let fitted = try #require(IconPixelGrid.fit([ring], toDevice: toDevice).first)
        let box = fitted.path.boundingBoxOfPath.applying(toDevice)
        let stroke = fitted.width * 16 * scale / 24
        #expect(abs(stroke - scale) < 1e-6)
        #expect(abs(box.width - box.height) < 1e-6)
        #expect(abs(box.width - box.width.rounded()) < 1e-6)
        let phase: CGFloat = scale == 1 ? 0.5 : 0
        for edge in [box.minX, box.maxX, box.minY, box.maxY] {
            #expect(abs((edge - phase) - (edge - phase).rounded()) < 1e-6, "\(edge)")
        }
    }

    /// A ring and the cross inside it share one center after fitting.
    @Test func aRingAndItsCrossStayConcentric() throws {
        let layers = [
            IconLayer(d: "M20.5 12C20.5 16.694 16.694 20.5 12 20.5C7.306 20.5 3.5 16.694 3.5 12C3.5 7.306 7.306 3.5 12 3.5C16.694 3.5 20.5 7.306 20.5 12Z", op: .stroke),
            IconLayer(d: "M12 8L12 16M8 12L16 12", op: .stroke),
        ]
        let toDevice = CGAffineTransform(scaleX: 16 / 24, y: 16 / 24)
        let fitted = IconPixelGrid.fit(layers, toDevice: toDevice)
        let ring = fitted[0].path.boundingBoxOfPath.applying(toDevice)
        let cross = fitted[1].path.boundingBoxOfPath.applying(toDevice)
        #expect(abs(ring.midX - cross.midX) < 1e-6)
        #expect(abs(ring.midY - cross.midY) < 1e-6)
    }
}
