import AppKit
import CmuxNextDesign
@testable import CmuxNextBrowser
import Testing

/// User 2026-10-21: "i dont like the svgs for the icons". The page menu's Chrome rows (Translate,
/// Cast) and an extension row without its own icon show SF Symbols, not the icon pack's drawings
/// of Chrome's vector icons.
@MainActor @Suite struct BrowserContextMenuIconTests {
    @Test(arguments: [("browser.menu.translate", "translate"), ("browser.menu.cast", "airplayvideo")])
    func aChromeRowShowsItsSystemSymbol(pack: String, symbol: String) throws {
        let image = BrowserContextMenuImages.make(.symbol(pack))
        let system = try #require(NSImage.menuSymbol(symbol))
        #expect(image.isTemplate)
        #expect(MenuIconPixels(image) == MenuIconPixels(system), "\(pack) draws SF Symbol \(symbol)")
    }

    @Test func theDefaultExtensionRowShowsThePuzzlePieceSymbol() throws {
        let image = BrowserContextMenuImages.make(.defaultExtension)
        let system = try #require(NSImage.menuSymbol("puzzlepiece.extension"))
        #expect(MenuIconPixels(image) == MenuIconPixels(system))
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
