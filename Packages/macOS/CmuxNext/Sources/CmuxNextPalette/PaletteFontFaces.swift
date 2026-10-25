import AppKit

/// The fonts a font setting's palette rows draw their names in (`PaletteItem.fontFamily`), one per
/// family and size, kept for the process: a font made and dropped at once can come back null from
/// AppKit (CheckedFont), and the list redraws every row as the highlight moves. A family that is
/// not installed has no font, so its row draws in the body font.
@MainActor
final class PaletteFontFaces {
    static let shared = PaletteFontFaces()
    private struct Key: Hashable {
        var family: String
        var size: CGFloat
    }

    /// Families a font list shows are the installed fixed-pitch ones (a few hundred at most).
    private static let limit = 1024
    private var fonts: [Key: NSFont?] = [:]

    func font(family: String, size: CGFloat) -> NSFont? {
        let key = Key(family: family, size: size)
        if let font = fonts[key] { return font }
        let made = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
        if fonts.count < Self.limit { fonts[key] = made }
        return made
    }
}
