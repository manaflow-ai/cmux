public import AppKit
import CmuxNextIcons

extension NSImage {
    /// A menu row's icon: the SF Symbol `name` as a template, at the menu font's size, so AppKit
    /// inks it like the row's title (white in dark mode, black in light) and follows its highlight. Every right-click menu's
    /// icons are system symbols, the ones Finder and Safari use, never the icon pack's drawings
    /// (user 2026-10-21: "i dont like the svgs for the icons"). Rows that run an action use that
    /// action's `ActionDescriptor.symbol`.
    ///
    /// `name` may also be an icon pack name (`browser.menu.cast`): it draws as the SF Symbol the
    /// icon catalog pairs with it (`airplayvideo`). Nil when neither names a symbol.
    public static func menuSymbol(_ name: String) -> NSImage? {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name : IconCatalog.bundled.entry(for: IconName(name))?.sf
        guard let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                  .withSymbolConfiguration(menuSymbolConfiguration)
        else { return nil }
        image.isTemplate = true
        return image
    }

    /// ``menuSymbol(_:)`` centered in a `size` square, still a template the menu tints: a menu
    /// whose rows mix symbols, emoji and empty squares (browser profiles) keeps every title in one
    /// column.
    /// - Parameters:
    ///   - name: An SF Symbol or bundled icon name, as for ``menuSymbol(_:)``.
    ///   - size: The square every row's image has.
    /// - Returns: The square image, or nil when `name` names no symbol.
    public static func menuSymbol(_ name: String, centeredIn size: NSSize) -> NSImage? {
        guard let symbol = menuSymbol(name) else { return nil }
        let square = NSImage(size: size, flipped: false) { rect in
            let drawn = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            return true
        }
        square.isTemplate = true
        return square
    }

    /// Native menus' symbol size: the menu font's point size, regular weight, medium scale.
    private static var menuSymbolConfiguration: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
    }
}
