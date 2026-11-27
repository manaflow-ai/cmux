import AppKit
import CmuxNextDesign
@testable import CmuxNextHomeEngine
import Testing

/// User 2026-10-21: "i dont like the svgs for the icons". The Home page's right-click rows show
/// the SF Symbol they name (as Finder's and Safari's menus do), not the icon pack's drawing of it.
@MainActor @Suite struct HomeMenuIconTests {
    @Test(arguments: ["square.and.pencil", "sparkles", "envelope", "trash", "doc.on.doc"])
    func aHomeMenuRowShowsTheSystemSymbol(symbol: String) throws {
        let item = HomeMenuTarget.item(title: "Row", symbol: symbol) {}
        let image = try #require(item.image)
        let system = try #require(NSImage.menuSymbol(symbol))
        #expect(image.isTemplate)
        #expect(MenuIconPixels(image) == MenuIconPixels(system), "\(symbol) draws the SF Symbol")
    }
}

/// An image's alpha drawn into a 32 x 32 px square: two images that draw the same pixels match.
private struct MenuIconPixels: Equatable {
    let alpha: [UInt8]

    @MainActor init(_ image: NSImage) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        alpha = (0..<32).flatMap { y in (0..<32).map { x in UInt8((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255) } }
    }
}
