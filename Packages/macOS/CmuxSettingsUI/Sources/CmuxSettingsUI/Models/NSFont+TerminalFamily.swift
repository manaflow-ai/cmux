import AppKit

extension NSFont {
    /// Ghostty's built-in font, used when no `font-family` is set.
    static let ghosttyBuiltInFamily = "JetBrains Mono"

    /// The regular face of `family` at `size`, for previewing a terminal font
    /// choice. `nil` means Ghostty's built-in font, which is shown with the
    /// installed JetBrains Mono when present and the system monospaced font
    /// otherwise. A family with no regular face falls back to its first member.
    static func terminalPreview(family: String?, size: CGFloat) -> NSFont {
        let manager = NSFontManager.shared
        let resolvedFamily = family ?? ghosttyBuiltInFamily
        if let font = manager.font(withFamily: resolvedFamily, traits: [], weight: 5, size: size) {
            return font
        }
        if let member = manager.availableMembers(ofFontFamily: resolvedFamily)?.first,
           let name = member.first as? String,
           let font = NSFont(name: name, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
