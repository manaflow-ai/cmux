import AppKit
import CmuxTerminalPrediction
import Testing

@testable import CmuxTerminal

@MainActor
@Suite("Predicted echo overlay rendering")
struct TerminalPredictionOverlayViewTests {
    /// Ghostty's terminal view is layer-hosting: its own IOSurface layer is
    /// the view's layer. A run presented over it has to come out as an image
    /// of the overlay's own cells, with the glyphs in it, without relying on
    /// AppKit's drawing pass for subviews of that view.
    @Test func aRunOverALayerHostingTerminalRendersItsGlyphsAtItsOwnSize() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 760, height: 644))
        host.layer = CALayer()
        host.wantsLayer = true
        let overlay = TerminalPredictionOverlayView(frame: .zero)
        host.addSubview(overlay)
        let style = TerminalPredictionOverlayView.Style(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            foreground: .black,
            background: .white,
            cursor: .black,
            cellSize: CGSize(width: 8, height: 17)
        )

        let shown = overlay.present(
            glyphs: [
                PredictedGlyph(character: "q", offset: 0, standing: .speculative),
                PredictedGlyph(character: "w", offset: 1, standing: .speculative),
            ],
            cursorColumn: 30,
            columns: 80,
            style: style,
            cursorOrigin: CGPoint(x: 242, y: 625)
        )
        overlay.updateLayer()

        #expect(shown)
        let layer = try #require(overlay.layer)
        let contents = try #require(layer.contents, "the overlay's layer has no contents")
        let image = contents as! CGImage
        #expect(image.width == Int((overlay.bounds.width * layer.contentsScale).rounded(.up)))
        #expect(image.height == Int((overlay.bounds.height * layer.contentsScale).rounded(.up)))
        #expect(darkPixelCount(in: image) > 0, "the glyphs are not in the rendered run")
    }

    private func darkPixelCount(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if red + green + blue < 200 { dark += 1 }
        }
        return dark
    }
}
