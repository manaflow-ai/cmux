import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// Blank first draws are transient: a symbol can rasterize to a fully
/// transparent bitmap while AppKit is still resolving the effective
/// appearance for a freshly hosted view. The sidebar footer controls
/// (account, iPhone, Help) showed this as icons that vanished while their
/// buttons stayed clickable, because the view only re-rendered on a window
/// or appearance change that never came. The next layout pass, which AppKit
/// runs once the view sits inside its window, is the recovery signal.
@MainActor
@Suite struct CmuxResolvedIconImageViewBlankRetryTests {
    private let size = NSSize(width: 16, height: 16)

    /// A blank first draw heals on the next layout pass once the source
    /// draws visible pixels, without a window move or appearance change.
    @Test func imageViewRecoversBlankRenderOnLayoutPass() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        let representation = transparentBitmapRepresentation(pixels: 16)
        let sourceImage = NSImage(size: size)
        sourceImage.addRepresentation(representation)

        view.apply(CmuxResolvedIconRequest(source: .image(sourceImage), size: size))
        #expect(renderedImage(in: view) == nil)

        fill(representation, color: .systemRed)
        view.layout()

        let pixel = try #require(renderedImage(in: view).flatMap(centerPixelColor))
        #expect(pixel.redComponent > pixel.blueComponent)
    }

    /// A source that stays blank stops re-rendering after the bounded number
    /// of layout passes, so a permanently empty icon never re-rasterizes on
    /// every layout.
    @Test func imageViewStopsRecoveringAfterBoundedLayoutPasses() {
        let view = CmuxResolvedIconImageView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        let sourceImage = NSImage(size: size)
        sourceImage.addRepresentation(transparentBitmapRepresentation(pixels: 16))

        view.apply(CmuxResolvedIconRequest(source: .image(sourceImage), size: size))
        for _ in 0..<(CmuxResolvedIconImageView.blankRecoveryLayoutPasses + 2) {
            view.layout()
        }

        #expect(renderedImage(in: view) == nil)
        #expect(view.blankRecoveryPassesUsed == CmuxResolvedIconImageView.blankRecoveryLayoutPasses)
    }

    /// A new request gets a fresh recovery budget and renders immediately.
    @Test func imageViewResetsRecoveryBudgetWhenRequestChanges() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(named: .aqua)
        let blankImage = NSImage(size: size)
        blankImage.addRepresentation(transparentBitmapRepresentation(pixels: 16))
        view.apply(CmuxResolvedIconRequest(source: .image(blankImage), size: size))
        view.layout()
        #expect(view.blankRecoveryPassesUsed == 1)

        let visibleImage = NSImage(size: size)
        visibleImage.addRepresentation(solidBitmapRepresentation(color: .systemBlue, pixels: 16))
        view.apply(CmuxResolvedIconRequest(source: .image(visibleImage), size: size))

        #expect(view.blankRecoveryPassesUsed == 0)
        let pixel = try #require(renderedImage(in: view).flatMap(centerPixelColor))
        #expect(pixel.blueComponent > pixel.redComponent)
    }

    private func renderedImage(in view: CmuxResolvedIconImageView) -> NSImage? {
        view.subviews.compactMap { ($0 as? NSImageView)?.image }.first
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
        fill(representation, color: color, operation: .copy)
        return representation
    }

    private func transparentBitmapRepresentation(pixels: Int) -> NSBitmapImageRep {
        solidBitmapRepresentation(color: .clear, pixels: pixels)
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

    private func centerPixelColor(in image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let x = max(0, min(bitmap.pixelsWide - 1, bitmap.pixelsWide / 2))
        let y = max(0, min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh / 2))
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }
}
