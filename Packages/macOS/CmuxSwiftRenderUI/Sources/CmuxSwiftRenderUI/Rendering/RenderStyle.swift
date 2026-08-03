import AppKit
import CmuxFoundation

func dslColor(_ token: String?) -> NSColor? {
    guard let token, !token.isEmpty else { return nil }
    switch token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "accent", "accentcolor": return .controlAccentColor
    case "primary": return .labelColor
    case "secondary": return .secondaryLabelColor
    case "tertiary": return .tertiaryLabelColor
    case "quaternary": return .quaternaryLabelColor
    case "red": return .systemRed
    case "orange": return .systemOrange
    case "yellow": return .systemYellow
    case "green": return .systemGreen
    case "mint": return .systemMint
    case "teal": return .systemTeal
    case "cyan": return .systemCyan
    case "blue": return .systemBlue
    case "indigo": return .systemIndigo
    case "purple": return .systemPurple
    case "pink": return .systemPink
    case "brown": return .systemBrown
    case "gray", "grey": return .systemGray
    case "white": return .white
    case "black": return .black
    case "clear": return .clear
    default: break
    }
    return NSColor(hex: token)
}

func dslFontSpec(
    named token: String?,
    size: Double?,
    weight: NSFont.Weight? = nil,
    design: DSLFontDesign = .default
) -> DSLFontSpec? {
    if let size {
        return DSLFontSpec(baseSize: CGFloat(size), weight: weight, design: design)
    }
    guard let token else { return nil }
    switch token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "largetitle": return DSLFontSpec(baseSize: 26, weight: weight, design: design)
    case "title": return DSLFontSpec(baseSize: 22, weight: weight, design: design)
    case "title2": return DSLFontSpec(baseSize: 17, weight: weight, design: design)
    case "title3": return DSLFontSpec(baseSize: 15, weight: weight, design: design)
    case "headline": return DSLFontSpec(baseSize: 13, weight: weight ?? .semibold, design: design)
    case "subheadline": return DSLFontSpec(baseSize: 11, weight: weight, design: design)
    case "body": return DSLFontSpec(baseSize: 13, weight: weight, design: design)
    case "callout": return DSLFontSpec(baseSize: 12, weight: weight, design: design)
    case "footnote", "caption": return DSLFontSpec(baseSize: 10, weight: weight, design: design)
    case "caption2": return DSLFontSpec(baseSize: 9, weight: weight, design: design)
    default: return nil
    }
}

func dslFont(_ spec: DSLFontSpec?) -> NSFont? {
    guard let spec else { return nil }
    let pointSize = GlobalFontMagnification.scaled(spec.baseSize)
    let weight = spec.weight ?? .regular
    switch spec.design {
    case .monospaced:
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
    case .default:
        return NSFont.systemFont(ofSize: pointSize, weight: weight)
    case .rounded, .serif:
        let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
        let systemDesign: NSFontDescriptor.SystemDesign = spec.design == .rounded ? .rounded : .serif
        guard let descriptor = base.fontDescriptor.withDesign(systemDesign) else { return base }
        return NSFont(descriptor: descriptor, size: pointSize) ?? base
    }
}

func dslFontWeight(_ token: String?) -> NSFont.Weight? {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
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

func dslFontDesign(_ token: String?) -> DSLFontDesign? {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "monospaced": return .monospaced
    case "rounded": return .rounded
    case "serif": return .serif
    case "default": return .default
    default: return nil
    }
}

func dslTextAlignment(_ token: String?) -> NSTextAlignment {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "center": return .center
    case "trailing", "right": return .right
    default: return .left
    }
}

enum DSLTextCase {
    case uppercase
    case lowercase
}

func dslTextCase(_ token: String?) -> DSLTextCase? {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "uppercase": return .uppercase
    case "lowercase": return .lowercase
    default: return nil
    }
}

func dslTruncationMode(_ token: String?) -> NSLineBreakMode {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "head": return .byTruncatingHead
    case "middle": return .byTruncatingMiddle
    default: return .byTruncatingTail
    }
}

func dslImageScale(_ token: String?) -> CGFloat {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "small": return 0.8
    case "large": return 1.25
    default: return 1
    }
}

func dslUnitPoint(_ token: String?, default fallback: CGPoint) -> CGPoint {
    switch token?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
    case "top": return CGPoint(x: 0.5, y: 0)
    case "bottom": return CGPoint(x: 0.5, y: 1)
    case "leading": return CGPoint(x: 0, y: 0.5)
    case "trailing": return CGPoint(x: 1, y: 0.5)
    case "topleading": return CGPoint(x: 0, y: 0)
    case "toptrailing": return CGPoint(x: 1, y: 0)
    case "bottomleading": return CGPoint(x: 0, y: 1)
    case "bottomtrailing": return CGPoint(x: 1, y: 1)
    case "center": return CGPoint(x: 0.5, y: 0.5)
    default: return fallback
    }
}

func dslKeyEquivalent(_ token: String?) -> String? {
    guard let raw = token?.trimmingCharacters(in: CharacterSet(charactersIn: ".\" ")), !raw.isEmpty
    else {
        return nil
    }
    switch raw.lowercased() {
    case "return": return "\r"
    case "escape": return "\u{1b}"
    case "space": return " "
    case "tab": return "\t"
    case "delete": return "\u{7f}"
    case "uparrow": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
    case "downarrow": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
    case "leftarrow": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case "rightarrow": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
    default: return String(raw.prefix(1))
    }
}

func dslEventModifiers(_ source: String?) -> NSEvent.ModifierFlags {
    guard let source = source?.lowercased() else { return [] }
    var modifiers: NSEvent.ModifierFlags = []
    if source.contains("command") {
        modifiers.insert(.command)
    }
    if source.contains("shift") {
        modifiers.insert(.shift)
    }
    if source.contains("option") {
        modifiers.insert(.option)
    }
    if source.contains("control") {
        modifiers.insert(.control)
    }
    return modifiers
}
