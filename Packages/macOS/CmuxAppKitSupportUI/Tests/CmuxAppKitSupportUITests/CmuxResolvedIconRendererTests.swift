import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct CmuxResolvedIconRendererTests {
    @Test func templateSymbolRendersVisibleRasterInResolvedAppearance() throws {
        let renderer = CmuxResolvedIconRenderer()
        let request = CmuxResolvedIconRequest(
            source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .secondaryLabelColor,
            symbolWeight: .regular
        )
        let appearance = try #require(NSAppearance(named: .aqua))
        let image = try #require(renderer.image(for: request, appearance: appearance))

        #expect(image.isTemplate == false)
        #expect(visiblePixelCount(in: image) > 0)
    }

    @Test func imageViewRerendersWhenEffectiveAppearanceChanges() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "doc", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .labelColor,
            symbolWeight: .regular
        ))
        let lightImage = try #require(renderedImage(in: view))

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        let darkImage = try #require(renderedImage(in: view))

        #expect(darkImage !== lightImage)
        #expect(visiblePixelCount(in: darkImage) > 0)
    }

    @Test func imageViewRerendersWhenEffectiveAppearanceHasSameAquaBestMatch() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "doc", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .labelColor,
            symbolWeight: .regular
        ))
        let lightImage = try #require(renderedImage(in: view))

        view.appearance = NSAppearance(named: .vibrantLight)
        view.viewDidChangeEffectiveAppearance()
        let vibrantImage = try #require(renderedImage(in: view))

        #expect(vibrantImage !== lightImage)
        #expect(visiblePixelCount(in: vibrantImage) > 0)
    }

    @Test func imageViewSkipsRenderWhenRequestAndAppearanceAreUnchanged() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "doc", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .labelColor,
            symbolWeight: .regular
        ))
        let firstImage = try #require(renderedImage(in: view))

        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "doc", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .labelColor,
            symbolWeight: .regular
        ))

        #expect(renderedImage(in: view) === firstImage)
    }

    @Test func imageViewRerendersWhenImagePixelsChangeInPlace() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        let representation = solidBitmapRepresentation(color: .systemRed, pixels: 16)
        sourceImage.addRepresentation(representation)
        let request = CmuxResolvedIconRequest(
            source: .image(sourceImage),
            size: NSSize(width: 16, height: 16)
        )
        view.apply(request)
        let firstImage = try #require(renderedImage(in: view))
        let firstPixel = try #require(centerPixelColor(in: firstImage))
        #expect(firstPixel.redComponent > firstPixel.blueComponent)
        prewarmImageCache(sourceImage)

        fill(representation, color: .systemBlue)
        view.apply(request)
        let updatedImage = try #require(renderedImage(in: view))
        let updatedPixel = try #require(centerPixelColor(in: updatedImage))

        #expect(updatedImage !== firstImage)
        #expect(updatedPixel.blueComponent > updatedPixel.redComponent)
        #expect(visiblePixelCount(in: updatedImage) > 0)
    }

    @Test func pngDataUsesRenderedNonTemplateImage() throws {
        let renderer = CmuxResolvedIconRenderer()
        let request = CmuxResolvedIconRequest(
            source: .systemSymbol(name: "sparkles", accessibilityDescription: nil),
            size: NSSize(width: 18, height: 18),
            tintColor: .systemBlue,
            symbolWeight: .medium
        )
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let data = try #require(renderer.pngData(for: request, appearance: appearance))

        #expect(data.isEmpty == false)
        let image = try #require(NSImage(data: data))
        #expect(image.isTemplate == false)
        #expect(visiblePixelCount(in: image) > 0)
    }

    @Test func transparentRasterIsRejectedAsRenderFailure() throws {
        let renderer = CmuxResolvedIconRenderer()
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        sourceImage.addRepresentation(transparentBitmapRepresentation(pixels: 16))
        let appearance = try #require(NSAppearance(named: .aqua))

        let result = renderer.render(
            for: CmuxResolvedIconRequest(
                source: .image(sourceImage),
                size: NSSize(width: 16, height: 16)
            ),
            appearance: appearance
        )

        #expect(result == .failure(.blankOutput))
    }

    @Test func imageViewPreservesLastGoodImageWhenRenderProducesBlankPixels() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        let sourceImage = NSImage(size: NSSize(width: 16, height: 16))
        let representation = solidBitmapRepresentation(color: .systemRed, pixels: 16)
        sourceImage.addRepresentation(representation)
        let request = CmuxResolvedIconRequest(
            source: .image(sourceImage),
            size: NSSize(width: 16, height: 16)
        )
        view.apply(request)
        let firstImage = try #require(renderedImage(in: view))
        let firstPixel = try #require(centerPixelColor(in: firstImage))
        #expect(firstPixel.redComponent > firstPixel.blueComponent)

        fill(representation, color: .clear, operation: .copy)
        view.apply(request)
        let preservedImage = try #require(renderedImage(in: view))
        let preservedPixel = try #require(centerPixelColor(in: preservedImage))

        #expect(preservedImage === firstImage)
        #expect(preservedPixel.redComponent > preservedPixel.blueComponent)
    }

    @Test func imageViewClearsPreviousImageWhenDifferentRequestRendersBlankPixels() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.appearance = NSAppearance(named: .aqua)
        let visibleImage = NSImage(size: NSSize(width: 16, height: 16))
        visibleImage.addRepresentation(solidBitmapRepresentation(color: .systemRed, pixels: 16))
        view.apply(CmuxResolvedIconRequest(
            source: .image(visibleImage),
            size: NSSize(width: 16, height: 16)
        ))
        #expect(renderedImage(in: view) != nil)

        let blankImage = NSImage(size: NSSize(width: 16, height: 16))
        blankImage.addRepresentation(transparentBitmapRepresentation(pixels: 16))
        view.apply(CmuxResolvedIconRequest(
            source: .image(blankImage),
            size: NSSize(width: 16, height: 16)
        ))

        #expect(renderedImage(in: view) == nil)
    }

    private func solidBitmapRepresentation(color: NSColor, pixels: Int) -> NSBitmapImageRep {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        representation.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        color.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    private func transparentBitmapRepresentation(pixels: Int) -> NSBitmapImageRep {
        let representation = solidBitmapRepresentation(color: .clear, pixels: pixels)
        fill(representation, color: .clear, operation: .copy)
        return representation
    }

    private func fill(
        _ representation: NSBitmapImageRep,
        color: NSColor,
        operation: NSCompositingOperation = .sourceOver
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        color.setFill()
        NSRect(origin: .zero, size: representation.size).fill(using: operation)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func renderedImage(in view: CmuxResolvedIconImageView) -> NSImage? {
        view.subviews.compactMap { ($0 as? NSImageView)?.image }.first
    }

    private func prewarmImageCache(_ image: NSImage) {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return
        }
        bitmap.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func centerPixelColor(in image: NSImage) -> NSColor? {
        guard let bitmap = bitmapRepresentation(in: image) else { return nil }
        let x = max(0, min(bitmap.pixelsWide - 1, bitmap.pixelsWide / 2))
        let y = max(0, min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh / 2))
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }

    private func visiblePixelCount(in image: NSImage) -> Int {
        guard let bitmap = bitmapRepresentation(in: image) else {
            return 0
        }
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    count += 1
                }
            }
        }
        return count
    }

    private func bitmapRepresentation(in image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}
