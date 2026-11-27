public import AppKit
import CmuxNextDesign
public import SwiftUI

/// Session colors arrive as `#RRGGBB` from the CUA host (the cursor color).
public nonisolated enum AgentActivityColor {
    /// The session's color; an unreadable one is the app theme's tertiary ink, not the system gray.
    public static func nsColor(hex: String) -> NSColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return ThemeTokens.unresolved.textTertiary.nsColor }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    public static func color(hex: String) -> Color { Color(nsColor: nsColor(hex: hex)) }
}
