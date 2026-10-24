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
    ///
    /// The symbol is made once per row: a lookup that made it and threw it away, then a second
    /// copy, parsed its SVG twice per row (sweep 2026-10-23: 169 ms of main thread in one STRESS
    /// Responsive Design menu of dozens of rows).
    public static func menuSymbol(_ name: String) -> NSImage? {
        func symbol(_ name: String?) -> NSImage? { name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } }
        guard let image = (symbol(name) ?? symbol(IconCatalog.bundled.entry(for: IconName(name))?.sf))?
            .withSymbolConfiguration(menuSymbolConfiguration)
        else { return nil }
        image.isTemplate = true
        return image
    }

    /// Native menus' symbol size: the menu font's point size, regular weight, medium scale.
    private static var menuSymbolConfiguration: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular, scale: .medium)
    }
}
