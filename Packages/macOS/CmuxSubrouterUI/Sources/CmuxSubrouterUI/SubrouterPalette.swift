internal import SwiftUI

/// The subrouter panel's palette: exactly two flat colors. Brand blue
/// (the cmux logo's #2D8CFF) while an account has headroom, system red
/// once it needs attention (≥90% used — the `sr` CLI's red threshold).
/// No gradients and no intermediate hues: a row is either fine (blue)
/// or needs attention (red), readable at a glance.
enum SubrouterPalette {
    static let blue = Color(red: 0x2D / 255, green: 0x8C / 255, blue: 0xFF / 255)

    /// The color for a window's severity: blue with headroom, red once
    /// the window needs attention.
    static func usageTier(for usedPercent: Double) -> Color {
        usedPercent >= 90 ? .red : blue
    }

    /// The flat fill for a usage bar.
    static func usageFill(for usedPercent: Double) -> AnyShapeStyle {
        AnyShapeStyle(usageTier(for: usedPercent))
    }

    /// The text color paired with ``usageFill(for:)``.
    static func usageAccent(for usedPercent: Double) -> Color {
        usageTier(for: usedPercent)
    }
}
