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

    /// An extension row's files decode in the menu's turn at 16 and 32 px, and only within the main thread's image
    /// gate (p03-rendering-121): a 512 px file (1 MiB of pixels) is not decoded there, so a row with only that file
    /// shows the default extension icon, as Chrome's does before the extension's icon is loaded.
    @Test func anExtensionRowDecodesItsFilesAtTheMenuSizeWithinTheMainThreadGate() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "menu-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ side: Int) throws -> String {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            let url = folder.appending(path: "\(side).png")
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            return url.path
        }
        let (small, medium, large) = (try file(16), try file(128), try file(512))

        let both = BrowserContextMenuImages.make(.image(oneX: small, twoX: medium))
        #expect(both.size == NSSize(width: 16, height: 16))
        #expect(both.representations.map(\.pixelsWide).sorted() == [16, 32], "the 128 px file decoded at the 2x size")
        let oneFile = BrowserContextMenuImages.make(.image(oneX: small, twoX: large))
        #expect(oneFile.representations.map(\.pixelsWide) == [16], "the 512 px file was decoded in the menu's turn")
        let none = BrowserContextMenuImages.make(.image(oneX: large, twoX: large))
        #expect(MenuIconPixels(none) == MenuIconPixels(BrowserContextMenuImages.make(.defaultExtension)))
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
