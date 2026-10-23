import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// User 2026-10-21: "for all the right click context menus i dont like the icons, they should be
/// whiter, and i dont like the svgs for the icons". A themed menu row's icon is an SF Symbol inked
/// like its title (white in dark mode, black in light), in every state, never the quieter grey of
/// the shortcut column, and never one of the pack's drawn icons.
@MainActor @Suite(.serialized) struct ThemedMenuIconTests {
    private static func scope(dark: Bool) -> ThemeScope {
        let input = dark
            ? ThemeInput(background: ThemeRGB(hex: 0x1C1B22), foreground: ThemeRGB(hex: 0xE8E4F0))
            : ThemeInput(background: ThemeRGB(hex: 0xF6F5F2), foreground: ThemeRGB(hex: 0x1D1C20))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(dark ? "Menu Dark" : "Menu Light"), input: input, animated: false)
        return scope
    }

    private static func row(symbol: String, dark: Bool, highlighted: Bool) throws -> ThemedMenuRowView {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Link", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        item.image = NSImage.menuSymbol(symbol)
        menu.addItem(item)
        menu.themeRows(in: scope(dark: dark))
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        row.frame.size.width = 240
        row.highlightOverride = highlighted
        return row
    }

    /// The strongest ink (alpha) drawn in the row between `minX` and `maxX`.
    private static func strongestInk(_ view: NSView, from minX: CGFloat, to maxX: CGFloat) throws -> CGFloat {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var strongest: CGFloat = 0
        for x in Int(minX * scale)..<Int(maxX * scale) {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                strongest = max(strongest, color.alphaComponent)
            }
        }
        return strongest
    }

    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func aTemplateIconIsInkedLikeTheTitle(dark: Bool, highlighted: Bool) throws {
        let row = try Self.row(symbol: "link", dark: dark, highlighted: highlighted)
        let iconX = ThemedMenuRowView.titleX
        let titleX = iconX + ThemedMenuRowView.imageSide + ThemedMenuRowView.gap
        let icon = try Self.strongestInk(row, from: iconX, to: iconX + ThemedMenuRowView.imageSide)
        let title = try Self.strongestInk(row, from: titleX, to: titleX + 50)
        #expect(icon > 0.1, "the icon draws")
        // A symbol's thin strokes antialias, so its peak sits a little under the text's: about 0.87
        // of it in the title's ink, about 0.6 in the quieter secondary ink rows used before.
        #expect(icon / title > 0.8, "icon ink \(icon) vs title ink \(title) (dark: \(dark), highlighted: \(highlighted))")
    }

    /// A pack name with no SF Symbol of the same name (Chrome's page-menu Cast) draws as the SF
    /// Symbol the icon catalog pairs with it, so every menu row's icon is a system symbol.
    @Test func aPackNameResolvesToItsSystemSymbol() throws {
        let image = try #require(NSImage.menuSymbol("browser.menu.cast"), "Cast has an SF Symbol: airplayvideo")
        #expect(image.isTemplate)
        let system = try #require(NSImage.menuSymbol("airplayvideo"))
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
