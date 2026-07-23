internal import SwiftUI

/// The subrouter panel's brand palette: the cmux logo chevron ramp
/// (web/public/cmux-icon.svg: #12c7f5 → #2d8cff@0.52 → #6c5cff), the same
/// source `ProBadgePalette` samples. Healthy usage renders in this ramp so
/// the panel reads as cmux; warning (≥70%) and critical (≥90%) keep the
/// semantic yellow/red because those colors carry meaning.
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

    /// The fill for a usage bar at `usedPercent`: the brand ramp while
    /// healthy, semantic yellow/red as the window saturates. Thresholds
    /// match the `sr` CLI.
    static func usageFill(for usedPercent: Double) -> AnyShapeStyle {
        if usedPercent >= 90 { return AnyShapeStyle(Color.red.gradient) }
        if usedPercent >= 70 { return AnyShapeStyle(Color.yellow.gradient) }
        return AnyShapeStyle(logoGradient)
    }

    /// The text/detail color paired with ``usageFill(for:)``: brand blue
    /// while healthy, semantic yellow/red as the window saturates.
    static func usageAccent(for usedPercent: Double) -> Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        return blue
    }
}
