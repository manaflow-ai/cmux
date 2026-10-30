import AppKit
@testable import CmuxNextFloating
import Testing

@MainActor @Suite struct ChiefPetIconTests {
    @Test func rotatedControlDrawsAtTheDisplayResolution() throws {
        // A drawing image, like NSImage.icon, must still receive the destination's scale after
        // rotation. Flattening it to one bitmap first makes the Retina chevron soft.
        var scales: [CGFloat] = []
        let source = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let transform = context.ctm
            scales.append(hypot(transform.a, transform.b))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect.insetBy(dx: 4, dy: 4))
            return true
        }
        source.cacheMode = .never
        source.isTemplate = true
        let rotated = ChiefPetTool.turned(source, by: 90)
        rotated.cacheMode = .never
        #expect(rotated.size == source.size)
        #expect(rotated.isTemplate)

        for scale: CGFloat in [1, 2] {
            scales.removeAll()
            let context = try #require(CGContext(data: nil, width: Int(18 * scale), height: Int(18 * scale),
                                                bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            rotated.draw(in: CGRect(origin: .zero, size: source.size))
            NSGraphicsContext.restoreGraphicsState()
            #expect(scales.contains { abs($0 - scale) < 0.01 }, "The source must draw at \(scale)x, not an earlier bitmap's scale")
        }
    }
}
