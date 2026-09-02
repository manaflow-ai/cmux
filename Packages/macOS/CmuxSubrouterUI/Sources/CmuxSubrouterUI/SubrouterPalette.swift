internal import SwiftUI

/// The subrouter panel's palette: exactly two flat colors. Brand blue
/// (the cmux logo's #2D8CFF) while an account has headroom, system red
/// once it needs attention (≥90% used — the `sr` CLI's red threshold).
/// No gradients and no intermediate hues: a row is either fine (blue)
/// or needs attention (red), readable at a glance.
enum SubrouterPalette {
    static let blue = Color(red: 0x2D / 255, green: 0x8C / 255, blue: 0xFF / 255)

    /// The used-percent threshold where a window needs attention — the
    /// `sr` CLI's red threshold.
    static let attentionThreshold: Double = 90

    /// The color for a window's severity: blue with headroom, red once
    /// the window needs attention.
    static func usageTier(for usedPercent: Double) -> Color {
        usedPercent >= attentionThreshold ? .red : blue
    }

    /// The flat fill for a usage bar.
    static func usageFill(for usedPercent: Double) -> AnyShapeStyle {
        AnyShapeStyle(usageTier(for: usedPercent))
    }

    /// The text color paired with ``usageFill(for:)``.
    static func usageAccent(for usedPercent: Double) -> Color {
        usageTier(for: usedPercent)
    }

    /// The row-summary label color. The mini gauge next to the label
    /// already carries the tier hue, so a wall of rows stays quiet:
    /// secondary text until the window crosses the attention threshold,
    /// red after.
    static func summaryText(for usedPercent: Double) -> Color {
        usedPercent >= attentionThreshold ? .red : Color.secondary
    }
}
