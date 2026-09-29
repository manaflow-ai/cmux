public import AppKit

/// Color tokens for cmux next.
///
/// Rule from plans/cmux-next/REWRITE.md: no blue accent anywhere. Selection,
/// focus, and hover are subtle grays. Every token resolves for light and dark
/// appearance, so views never branch on appearance themselves.
public enum Palette {
    /// Window background behind chrome and content.
    public static let windowBackground = dynamic(light: 0.93, dark: 0.11)

    /// Terminal content area background (never glass).
    public static let contentBackground = dynamic(light: 0.98, dark: 0.07)

    /// Primary text.
    public static let textPrimary = dynamic(light: 0.10, dark: 0.92)

    /// Secondary text, captions, inactive tab titles.
    public static let textSecondary = dynamic(light: 0.42, dark: 0.60)

    /// Hover fill for rows and tabs.
    public static let hoverFill = dynamic(light: 0.0, dark: 1.0, alpha: 0.06)

    /// Selected row or tab fill. Replaces the system blue selection.
    public static let selectionFill = dynamic(light: 0.0, dark: 1.0, alpha: 0.11)

    /// Focus ring and keyboard focus indicator. Replaces the system blue ring.
    public static let focusRing = dynamic(light: 0.35, dark: 0.70)

    /// Hairline separators.
    public static let separator = dynamic(light: 0.0, dark: 1.0, alpha: 0.10)

    /// Neutral tint applied to glass so it never picks up a colored cast.
    public static let glassTint = dynamic(light: 1.0, dark: 0.0, alpha: 0.08)

    /// The app accent. Deliberately a gray so any control that reads the
    /// accent stays neutral.
    public static let accent = focusRing

    private static func dynamic(light: CGFloat, dark: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: alpha)
        }
    }
}
