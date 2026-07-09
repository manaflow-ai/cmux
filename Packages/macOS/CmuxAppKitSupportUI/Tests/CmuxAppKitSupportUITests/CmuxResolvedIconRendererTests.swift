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
        let lightImage = try #require(view.renderedImage)

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        let darkImage = try #require(view.renderedImage)

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
        let lightImage = try #require(view.renderedImage)

        view.appearance = NSAppearance(named: .vibrantLight)
        view.viewDidChangeEffectiveAppearance()
        let vibrantImage = try #require(view.renderedImage)

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
        let firstImage = try #require(view.renderedImage)

        view.apply(CmuxResolvedIconRequest(
            source: .systemSymbol(name: "doc", accessibilityDescription: nil),
            size: NSSize(width: 16, height: 16),
            tintColor: .labelColor,
            symbolWeight: .regular
        ))

        #expect(view.renderedImage === firstImage)
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
