import AppKit
import Testing

@testable import CmuxAppKitSupportUI

/// The hosted renderer must be able to draw an SF Symbol at an explicit
/// configuration point size inside a larger natural-size slot, so hosted
/// symbols match the geometry of `NSImage.SymbolConfiguration(pointSize:)`.
@MainActor
@Suite struct CmuxResolvedIconSymbolPointSizeTests {
    @Test func explicitSymbolPointSizeDrawsSmallerGlyphThanSizeDerivedDefault() throws {
        let renderer = CmuxResolvedIconRenderer()
        let appearance = try #require(NSAppearance(named: .aqua))
        let slot = NSSize(width: 32, height: 32)

        let sizeDerived = try #require(renderer.image(
            for: CmuxResolvedIconRequest(
                source: .systemSymbol(name: "circle.fill", accessibilityDescription: nil),
                size: slot,
                tintColor: .labelColor
            ),
            appearance: appearance
        ))
        let explicit = try #require(renderer.image(
            for: CmuxResolvedIconRequest(
                source: .systemSymbol(name: "circle.fill", accessibilityDescription: nil),
                size: slot,
                tintColor: .labelColor,
                symbolPointSize: 8
            ),
            appearance: appearance
        ))

        let defaultPixels = visiblePixelCount(in: sizeDerived)
        let explicitPixels = visiblePixelCount(in: explicit)
        #expect(explicitPixels > 0)
        #expect(explicitPixels * 2 < defaultPixels)
        #expect(explicit.size == slot)
    }

    @Test func explicitSymbolPointSizeMatchesAppKitConfiguredSymbolCoverage() throws {
        let systemName = "person.crop.circle"
        let pointSize: CGFloat = 14
        let base = try #require(NSImage(systemSymbolName: systemName, accessibilityDescription: nil))
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let configured = try #require(base.withSymbolConfiguration(configuration))
        let naturalSize = configured.size
        #expect(naturalSize.width > pointSize)

        let renderer = CmuxResolvedIconRenderer()
        let appearance = try #require(NSAppearance(named: .aqua))
        let hosted = try #require(renderer.image(
            for: CmuxResolvedIconRequest(
                source: .systemSymbol(name: systemName, accessibilityDescription: nil),
                size: naturalSize,
                tintColor: .labelColor,
                symbolWeight: .regular,
                symbolPointSize: pointSize
            ),
            appearance: appearance
        ))
        #expect(hosted.size == naturalSize)

        let expected = try #require(directDraw(configured, size: naturalSize))
        let expectedPixels = visiblePixelCount(in: expected)
        let hostedPixels = visiblePixelCount(in: hosted)
        #expect(expectedPixels > 0)
        #expect(abs(hostedPixels - expectedPixels) <= expectedPixels / 10)
    }

    @Test func imageViewRerendersWhenSymbolPointSizeChanges() throws {
        let view = CmuxResolvedIconImageView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        view.appearance = NSAppearance(named: .aqua)
        let slot = NSSize(width: 32, height: 32)
        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "circle.fill", accessibilityDescription: nil),
            size: slot,
            tintColor: .labelColor,
            symbolPointSize: 8
        ))
        let small = try #require(renderedImage(in: view))
        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "circle.fill", accessibilityDescription: nil),
            size: slot,
            tintColor: .labelColor,
            symbolPointSize: 24
        ))
        let large = try #require(renderedImage(in: view))

        #expect(large !== small)
        #expect(visiblePixelCount(in: large) > visiblePixelCount(in: small))
    }

    private func renderedImage(in view: CmuxResolvedIconImageView) -> NSImage? {
        view.subviews.compactMap { $0 as? NSImageView }.first?.image
    }

    private func directDraw(_ image: NSImage, size: NSSize) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * 2)),
            pixelsHigh: Int(ceil(size.height * 2)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let rendered = NSImage(size: size)
        rendered.addRepresentation(bitmap)
        return rendered
    }

    private func visiblePixelCount(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
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
}
