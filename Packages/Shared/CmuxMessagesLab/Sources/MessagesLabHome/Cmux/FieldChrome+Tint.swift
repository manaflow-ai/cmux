import AppKit

extension FieldChrome {
    /// How much of the theme background tints the compose glass on a light theme.
    static let lightGlassTintAlpha: CGFloat = 0.55

    /// cmux: the compose glass's tint for a theme. Light: the theme background at
    /// ``lightGlassTintAlpha``, so a sent bubble that scrolls under the field and its
    /// buttons reads as a dimmed blue instead of the clear glass's brightened cyan smear.
    /// Dark: nil, MessagesLab's untinted glass (its measured dark field).
    static func glassTint(light: Bool, background: NSColor) -> NSColor? {
        light ? background.withAlphaComponent(lightGlassTintAlpha) : nil
    }

    /// Tints the field, "+" and emoji glass (macOS 26 system glass; the macOS 14 and 15
    /// visual-effect stand-in has no tint and keeps its material).
    func applyGlassTint(_ tint: NSColor?) {
        guard #available(macOS 26, *) else { return }
        let surfaces: [any LabGlassSurface] = [field, plusGlass, emojiGlass]
        for case let glass as NSGlassEffectView in surfaces where glass.tintColor != tint { glass.tintColor = tint }
    }
}
