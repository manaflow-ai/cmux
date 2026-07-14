import SwiftUI

/// Hex-string color parsing for the render-grid palette.
///
/// The host emits colors as `#RRGGBB` strings (already resolved from its
/// theme), so the viewer only needs literal parsing plus sensible defaults.
enum HiveTerminalColor {
    /// Default background when the host reported none.
    static let fallbackBackground = Color(red: 0.09, green: 0.09, blue: 0.11)
    /// Default foreground when the host reported none.
    static let fallbackForeground = Color(red: 0.92, green: 0.92, blue: 0.94)

    /// Parse a `#RRGGBB` / `RRGGBB` hex string.
    static func parse(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
