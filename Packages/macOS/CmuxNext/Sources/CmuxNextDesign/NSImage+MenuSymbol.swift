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
        if let drawn = packOverride(forSymbol: name, pointSize: NSFont.menuFont(ofSize: 0).pointSize) { return drawn }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name : IconCatalog.bundled.entry(for: IconName(name))?.sf
        guard let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                  .withSymbolConfiguration(menuSymbolConfiguration)
        else { return nil }
        image.isTemplate = true
        return image
    }

    /// The icon pack's drawing that stands in for SF Symbol `name` (`IconCatalog.name(overriding:)`: the globe and the
    /// terminal prompt, Leo 2026-11-09: "just draw that basketball instead of that busy thing"), as a template sized to
    /// match the symbol at `pointSize`, or nil to draw the symbol. A symbol at point size p draws a ring about p across
    /// with a stroke of about p / 12; the pack's ring spans 18.3 of its 24 units at a 1.5 stroke, so the square is 4/3 p.
    public static func packOverride(forSymbol name: String, pointSize: CGFloat) -> NSImage? {
        guard let icon = IconCatalog.bundled.name(overriding: name) else { return nil }
        return NSImage.icon(icon, size: (pointSize * 4 / 3).rounded())
    }

    /// Native menus' symbol size: the menu font's point size, regular weight, medium scale.
    private static var menuSymbolConfiguration: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
    }
}
