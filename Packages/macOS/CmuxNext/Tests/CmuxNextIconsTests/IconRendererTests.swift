import CoreGraphics
@testable import CmuxNextIcons
import Testing

/// Renders into an RGBA bitmap and reads its alpha channel.
struct IconRendererTests {
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
            // Flip so y points down, as in a flipped view.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
        }

        func alpha(x: Int, y: Int) throws -> UInt8 {
            let data = try #require(context.data)
            return data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + 3, as: UInt8.self)
        }

        func inkedPixels() throws -> Int {
            var count = 0
            for y in 0..<context.height {
                for x in 0..<context.width {
                    if try alpha(x: x, y: y) > 0 {
                        count += 1
                    }
                }
            }
            return count
        }
    }

    private static let ink = CGColor(gray: 0, alpha: 1)

    @Test func drawsTheCloseIcon() throws {
        let layers = try #require(IconPack.bundled.drawing(for: .actionClose)?.line)
        let bitmap = try Bitmap(side: 32)
        IconRenderer.draw(layers, in: bitmap.context, rect: CGRect(x: 0, y: 0, width: 32, height: 32), ink: Self.ink)
        #expect(try bitmap.inkedPixels() > 0)
        #expect(try bitmap.alpha(x: 16, y: 16) > 0, "the x crosses the center")
    }

    @Test func aClearLayerErasesOnlyWhatEarlierLayersDrew() throws {
        let layers = [
            IconLayer(d: "M4 4L20 4L20 20L4 20Z", op: .fill),
            IconLayer(d: "M10 10L14 10L14 14L10 14Z", op: .clearFill),
        ]
        let bitmap = try Bitmap(side: 24)
        // Content already in the context, under the clear square.
        bitmap.context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        bitmap.context.fill(CGRect(x: 10, y: 10, width: 1, height: 1))
        IconRenderer.draw(layers, in: bitmap.context, rect: CGRect(x: 0, y: 0, width: 24, height: 24), ink: Self.ink)
        #expect(try bitmap.alpha(x: 12, y: 12) == 0)
        #expect(try bitmap.alpha(x: 5, y: 5) == 255)
        #expect(try bitmap.alpha(x: 10, y: 10) == 255, "content under the icon survives its clear layers")
    }

    @Test func cropMapsTheRowViewBoxOntoTheTarget() throws {
        let layers = [IconLayer(d: "M2.5 2.5L21.5 2.5L21.5 21.5L2.5 21.5Z", op: .fill)]
        let bitmap = try Bitmap(side: 19)
        IconRenderer.draw(
            layers,
            in: bitmap.context,
            rect: CGRect(x: 0, y: 0, width: 19, height: 19),
            ink: Self.ink,
            crop: IconRenderer.rowCrop
        )
        #expect(try bitmap.inkedPixels() == 19 * 19)
    }
}
