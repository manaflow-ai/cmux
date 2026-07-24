internal import SwiftUI

/// The subrouter panel's brand palette: the cmux logo chevron ramp
/// (web/public/cmux-icon.svg: #12c7f5 → #2d8cff@0.52 → #6c5cff), the same
/// source `ProBadgePalette` samples.
///
/// Usage severity is a four-tier scheme: brand hues while the account is
/// fine (cyan fresh, blue well used), semantic hues once it needs
/// attention (yellow at ≥70%, red at ≥90% — the `sr` CLI's thresholds).
/// So a healthy panel reads as cmux, and warning colors appear exactly
/// when they carry information. The full ramp is reserved for
/// distribution visuals (the activity chart) where no per-item state is
/// being encoded.
enum SubrouterPalette {
    static let cyan = Color(red: 0x12 / 255, green: 0xC7 / 255, blue: 0xF5 / 255)
    static let blue = Color(red: 0x2D / 255, green: 0x8C / 255, blue: 0xFF / 255)
    static let violet = Color(red: 0x6C / 255, green: 0x5C / 255, blue: 0xFF / 255)

    /// The full logo ramp, for wide fills (activity bars, full-width
    /// usage bars).
    static let logoGradient = LinearGradient(
        stops: [
            .init(color: cyan, location: 0),
            .init(color: blue, location: 0.52),
            .init(color: violet, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The mid-ramp slice (#249FFC → #4B75FF) used where the full sweep
    /// would be garish at small sizes — mirrors `ProBadgePalette`.
    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0x24 / 255, green: 0x9F / 255, blue: 0xFC / 255),
            Color(red: 0x4B / 255, green: 0x75 / 255, blue: 0xFF / 255),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    /// The tier color for a window's severity: brand cyan/blue while
    /// comfortable, semantic yellow/red once it needs attention.
    static func usageTier(for usedPercent: Double) -> Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        if usedPercent >= 40 { return blue }
        return cyan
    }

    /// The fill for a usage bar: the severity stop with a subtle
    /// same-hue sheen.
    static func usageFill(for usedPercent: Double) -> AnyShapeStyle {
        AnyShapeStyle(usageTier(for: usedPercent).gradient)
    }

    /// The text color paired with ``usageFill(for:)``.
    static func usageAccent(for usedPercent: Double) -> Color {
        usageTier(for: usedPercent)
    }
}
