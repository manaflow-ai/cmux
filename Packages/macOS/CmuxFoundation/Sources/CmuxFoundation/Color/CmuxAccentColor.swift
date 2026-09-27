public import AppKit
public import SwiftUI

/// cmux's accent blue: the one color for cmux-drawn chrome that means
/// "this is the active or attention-worthy thing" (selected workspace,
/// attention ring, pane swap source, canvas focus, scroll markers).
///
/// It deliberately does not follow the macOS accent setting, so cmux chrome
/// stays one color instead of mixing the system accent with fixed blues.
/// Native controls (toggles, pickers, text cursors, list selection) keep the
/// system accent.
public enum CmuxAccentColor {
    /// The accent for a light or dark appearance.
    public static func nsColor(isDark: Bool) -> NSColor {
        NSColor(
            srgbRed: 0,
            green: (isDark ? 145.0 : 136.0) / 255.0,
            blue: 1.0,
            alpha: 1.0
        )
    }

    /// The accent for an AppKit appearance. `nil` resolves as light.
    public static func nsColor(for appearance: NSAppearance?) -> NSColor {
        nsColor(isDark: appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Appearance-aware accent that resolves against the drawing appearance,
    /// like a system dynamic color.
    public static var dynamicNSColor: NSColor {
        NSColor(name: "cmuxAccent") { appearance in
            nsColor(for: appearance)
        }
    }

    /// SwiftUI accent that follows the view's color scheme.
    public static var color: Color {
        Color(nsColor: dynamicNSColor)
    }
}
