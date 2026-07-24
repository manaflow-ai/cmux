internal import SwiftUI

/// The subrouter panel's brand palette: the cmux logo chevron ramp
/// (web/public/cmux-icon.svg: #12c7f5 → #2d8cff@0.52 → #6c5cff), the same
/// source `ProBadgePalette` samples. Every usage visual stays inside this
/// ramp: the gradient itself encodes severity, because a fuller bar
/// naturally sweeps further into the violet end, and accent text shifts
/// from blue to violet as a window saturates.
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

    /// The fill for a usage bar: always the brand ramp. A fuller bar
    /// reveals more of the violet end, so saturation is encoded by the
    /// gradient itself rather than by switching hues.
    static func usageFill(for usedPercent: Double) -> AnyShapeStyle {
        AnyShapeStyle(logoGradient)
    }

    /// The text color paired with ``usageFill(for:)``: brand blue while
    /// comfortable, ramp violet once the window is nearly exhausted.
    static func usageAccent(for usedPercent: Double) -> Color {
        usedPercent >= 90 ? violet : blue
    }
}
