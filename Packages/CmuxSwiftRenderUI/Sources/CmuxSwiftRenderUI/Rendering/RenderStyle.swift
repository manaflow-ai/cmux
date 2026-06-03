import SwiftUI

/// Resolves a style token to a SwiftUI `Color`.
///
/// Accepts `#RRGGBB`, `#RRGGBBAA`, a few named tokens, and `accent`. Returns
/// `nil` for unknown tokens so callers fall back to the default.
func dslColor(_ token: String?) -> Color? {
    guard let token, !token.isEmpty else { return nil }
    switch token.lowercased() {
    case "accent": return .accentColor
    case "primary": return .primary
    case "secondary": return .secondary
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "pink": return .pink
    case "gray", "grey": return .gray
    case "white": return .white
    case "black": return .black
    case "clear": return .clear
    default: break
    }
    guard token.hasPrefix("#") else { return nil }
    let hex = String(token.dropFirst())
    guard let value = UInt64(hex, radix: 16) else { return nil }
    let r, g, b, a: Double
    switch hex.count {
    case 6:
        r = Double((value >> 16) & 0xFF) / 255
        g = Double((value >> 8) & 0xFF) / 255
        b = Double(value & 0xFF) / 255
        a = 1
    case 8:
        r = Double((value >> 24) & 0xFF) / 255
        g = Double((value >> 16) & 0xFF) / 255
        b = Double((value >> 8) & 0xFF) / 255
        a = Double(value & 0xFF) / 255
    default:
        return nil
    }
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
}

/// Resolves a font token (or explicit size) to a SwiftUI `Font`.
func dslFont(named token: String?, size: Double?) -> Font? {
    if let size { return .system(size: size) }
    guard let token else { return nil }
    switch token.lowercased() {
    case "largetitle": return .largeTitle
    case "title": return .title
    case "title2": return .title2
    case "title3": return .title3
    case "headline": return .headline
    case "subheadline": return .subheadline
    case "body": return .body
    case "callout": return .callout
    case "footnote": return .footnote
    case "caption": return .caption
    case "caption2": return .caption2
    default: return nil
    }
}

/// Resolves a weight token to a SwiftUI `Font.Weight`.
func dslFontWeight(_ token: String?) -> Font.Weight? {
    switch token?.lowercased() {
    case "ultralight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return nil
    }
}

/// Resolves a horizontal-alignment token (default `.center`).
func dslHAlignment(_ token: String?) -> HorizontalAlignment {
    switch token?.lowercased() {
    case "leading": return .leading
    case "trailing": return .trailing
    default: return .center
    }
}

/// Resolves a vertical-alignment token (default `.center`).
func dslVAlignment(_ token: String?) -> VerticalAlignment {
    switch token?.lowercased() {
    case "top": return .top
    case "bottom": return .bottom
    default: return .center
    }
}
