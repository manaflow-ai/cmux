import CmuxFoundation
import SwiftUI

/// Resolves a style token to a SwiftUI `Color`.
///
/// Accepts `#RRGGBB`, `#RRGGBBAA`, a few named tokens, and `accent`. Returns
/// `nil` for unknown tokens so callers fall back to the default.
func dslColor(_ token: String?) -> Color? {
    guard let token, !token.isEmpty else { return nil }
    switch token.lowercased() {
    case "accent", "accentcolor": return .accentColor
    case "primary": return .primary
    case "secondary": return .secondary
    case "tertiary": return .secondary.opacity(0.6)
    case "quaternary": return .secondary.opacity(0.4)
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "mint": return .mint
    case "teal": return .teal
    case "cyan": return .cyan
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    case "brown": return .brown
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

/// Resolves a font token (or explicit size) to a magnification-aware font spec.
func dslFontSpec(named token: String?, size: Double?, weight: Font.Weight? = nil, design: Font.Design = .default) -> DSLFontSpec? {
    if let size { return DSLFontSpec(baseSize: CGFloat(size), weight: weight, design: design) }
    guard let token else { return nil }
    switch token.lowercased() {
    case "largetitle": return DSLFontSpec(baseSize: 26, weight: weight, design: design)
    case "title": return DSLFontSpec(baseSize: 22, weight: weight, design: design)
    case "title2": return DSLFontSpec(baseSize: 17, weight: weight, design: design)
    case "title3": return DSLFontSpec(baseSize: 15, weight: weight, design: design)
    case "headline": return DSLFontSpec(baseSize: 13, weight: weight ?? .semibold, design: design)
    case "subheadline": return DSLFontSpec(baseSize: 11, weight: weight, design: design)
    case "body": return DSLFontSpec(baseSize: 13, weight: weight, design: design)
    case "callout": return DSLFontSpec(baseSize: 12, weight: weight, design: design)
    case "footnote": return DSLFontSpec(baseSize: 10, weight: weight, design: design)
    case "caption": return DSLFontSpec(baseSize: 10, weight: weight, design: design)
    case "caption2": return DSLFontSpec(baseSize: 9, weight: weight, design: design)
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

/// Resolves a `Font.Design` token (`.monospaced`/`.rounded`/`.serif`/`.default`).
/// Returns `nil` for unknown tokens so the system design is kept.
func dslFontDesign(_ token: String?) -> Font.Design? {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "monospaced": return .monospaced
    case "rounded": return .rounded
    case "serif": return .serif
    case "default": return .default
    default: return nil
    }
}

/// Resolves a `TextAlignment` token (default `.leading`).
func dslTextAlignment(_ token: String?) -> TextAlignment {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "center": return .center
    case "trailing": return .trailing
    default: return .leading
    }
}

/// Resolves a `Text.Case` token; `nil` (the default) applies no transform.
func dslTextCase(_ token: String?) -> Text.Case? {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "uppercase": return .uppercase
    case "lowercase": return .lowercase
    default: return nil
    }
}

/// Resolves a `Text.TruncationMode` token (default `.tail`).
func dslTruncationMode(_ token: String?) -> Text.TruncationMode {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "head": return .head
    case "middle": return .middle
    default: return .tail
    }
}

/// Resolves an `Image.Scale` token (default `.medium`).
func dslImageScale(_ token: String?) -> Image.Scale {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "small": return .small
    case "large": return .large
    default: return .medium
    }
}

/// Resolves a `SymbolRenderingMode` token (default `.monochrome`).
func dslSymbolRenderingMode(_ token: String?) -> SymbolRenderingMode {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "hierarchical": return .hierarchical
    case "multicolor": return .multicolor
    case "palette": return .palette
    default: return .monochrome
    }
}

/// Resolves a `SymbolVariants` token (default `.none`).
func dslSymbolVariant(_ token: String?) -> SymbolVariants {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "fill": return .fill
    case "circle": return .circle
    case "square": return .square
    case "slash": return .slash
    default: return SymbolVariants.none
    }
}

/// Resolves a `UnitPoint` token (`top`, `bottomTrailing`, `center`, …).
func dslUnitPoint(_ token: String?, default fallback: UnitPoint) -> UnitPoint {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "top": return .top
    case "bottom": return .bottom
    case "leading": return .leading
    case "trailing": return .trailing
    case "topleading": return .topLeading
    case "toptrailing": return .topTrailing
    case "bottomleading": return .bottomLeading
    case "bottomtrailing": return .bottomTrailing
    case "center": return .center
    default: return fallback
    }
}

/// Resolves a `KeyEquivalent` token (`.return`/`.escape`/arrows/…) or a single
/// character; nil for unrecognized input.
func dslKeyEquivalent(_ token: String?) -> KeyEquivalent? {
    guard let raw = token?.trimmingCharacters(in: CharacterSet(charactersIn: ".\" ")), !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "return": return .return
    case "escape": return .escape
    case "space": return .space
    case "tab": return .tab
    case "delete": return .delete
    case "uparrow": return .upArrow
    case "downarrow": return .downArrow
    case "leftarrow": return .leftArrow
    case "rightarrow": return .rightArrow
    default: return raw.first.map { KeyEquivalent($0) }
    }
}

/// Resolves an `EventModifiers` set from a source token like
/// `[.command, .shift]`.
func dslEventModifiers(_ source: String?) -> EventModifiers {
    guard let source = source?.lowercased() else { return [] }
    var modifiers: EventModifiers = []
    if source.contains("command") { modifiers.insert(.command) }
    if source.contains("shift") { modifiers.insert(.shift) }
    if source.contains("option") { modifiers.insert(.option) }
    if source.contains("control") { modifiers.insert(.control) }
    return modifiers
}
