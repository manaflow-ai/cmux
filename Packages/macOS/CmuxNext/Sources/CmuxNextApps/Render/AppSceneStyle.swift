import AppKit
import CmuxNextDesign
import SwiftUI

/// Maps scene props to native styling: fonts to the chrome typography
/// scale, padding, frames, alignment (colors: `AppSceneColors`).
nonisolated enum AppSceneStyle {
    static func hexColor(_ text: String) -> NSColor? {
        guard text.hasPrefix("#"), text.count == 7 || text.count == 9, let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = text.count == 9
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `largeTitle ... caption2` or a point size; chrome-sized by default.
    @MainActor
    static func font(_ node: AppSceneNode) -> Font {
        var font: Font = switch node.props["font"] {
        case .number(let size)?: .system(size: max(6, min(size, 64)))
        case .string(let name)?: textStyle(name)
        default: Font(Typography.body)
        }
        if let weight = node.string("weight") { font = font.weight(Self.weight(weight)) }
        if node.flag("italic") { font = font.italic() }
        if node.flag("monospaced") { font = font.monospaced() }
        return font
    }

    @MainActor
    private static func textStyle(_ name: String) -> Font {
        switch name {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": Font(Typography.header)
        case "subheadline": .subheadline
        case "callout": .callout
        case "caption": Font(Typography.caption)
        case "caption2": .caption2
        default: Font(Typography.body)
        }
    }

    private static func weight(_ name: String) -> Font.Weight {
        switch name {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: .regular
        }
    }

    static func truncation(_ node: AppSceneNode) -> Text.TruncationMode {
        switch node.string("truncation") {
        case "head": .head
        case "middle": .middle
        default: .tail
        }
    }

    /// `padding`: a number or `{top, leading, bottom, trailing}`, plus the
    /// `paddingHorizontal` / `paddingVertical` shorthands.
    static func insets(_ node: AppSceneNode) -> EdgeInsets {
        var insets = EdgeInsets()
        switch node.props["padding"] {
        case .number(let all)?: insets = EdgeInsets(top: all, leading: all, bottom: all, trailing: all)
        case .object(let edges)?:
            insets = EdgeInsets(top: edges["top"]?.numberValue ?? 0, leading: edges["leading"]?.numberValue ?? 0,
                                bottom: edges["bottom"]?.numberValue ?? 0, trailing: edges["trailing"]?.numberValue ?? 0)
        default: break
        }
        if let h = node.number("paddingHorizontal") { insets.leading = h; insets.trailing = h }
        if let v = node.number("paddingVertical") { insets.top = v; insets.bottom = v }
        return insets
    }

    /// One `frame` dimension: a number, or `"infinity"`.
    static func dimension(_ frame: [String: AppJSON]?, _ key: String) -> CGFloat? {
        switch frame?[key] {
        case .number(let v)?: CGFloat(max(0, v))
        case .string("infinity")?: .infinity
        default: nil
        }
    }

    static func alignment(_ node: AppSceneNode) -> HorizontalAlignment {
        switch node.string("alignment") {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }
}
