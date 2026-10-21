public import AppKit

extension NSImage {
    /// A hand-built menu row's icon: the SF Symbol `name` as a template, so a themed row
    /// (`NSMenu.themeRows(in:)`) inks it like its title, as `ActionRegistry` gives catalog rows their
    /// action's symbol. Rows that run an action use that action's `ActionDescriptor.symbol`.
    public static func menuSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
