public import AppKit
public import SwiftUI

/// The one accent for cmux-drawn chrome: the color that means "this is the
/// active or attention-worthy thing" (selected workspace, attention ring,
/// pane swap source, canvas focus, scroll markers, agent status).
///
/// `app.accentColor` picks between cmux's fixed blue and the macOS accent
/// (see ``CmuxAccentColorMode``). Native controls (toggles, pickers, text
/// cursors, list selection) always keep the system accent. User overrides
/// such as the sidebar selection color or the pane flash color are applied
/// by their callers and win over both.
public enum CmuxAccentColor {
    /// Posted on the default center when the resolved accent changes, either
    /// because `app.accentColor` changed or because the macOS accent changed
    /// while following it. Layer-backed chrome re-applies its colors on it.
    public static let didChangeNotification = Notification.Name("cmux.accentColorDidChange")

    /// Hex the built-in agent hooks write for Running and Needs input. The
    /// sidebar draws entries carrying it with the accent instead.
    public static let builtInAgentStatusHex = "#4C8DFF"

    /// The accent for a light or dark appearance under the stored mode.
    public static func nsColor(isDark: Bool) -> NSColor {
        nsColor(isDark: isDark, mode: .stored())
    }

    /// The accent for a light or dark appearance under `mode`.
    public static func nsColor(isDark: Bool, mode: CmuxAccentColorMode) -> NSColor {
        switch mode {
        case .cmux:
            return NSColor(
                srgbRed: 0,
                green: (isDark ? 145.0 : 136.0) / 255.0,
                blue: 1.0,
                alpha: 1.0
            )
        case .system:
            return systemAccent(isDark: isDark)
        }
    }

    /// The accent for an AppKit appearance. `nil` resolves as light.
    public static func nsColor(for appearance: NSAppearance?) -> NSColor {
        nsColor(isDark: isDark(appearance))
    }

    /// Appearance-aware accent that resolves the stored mode and the drawing
    /// appearance each time it is used, like a system dynamic color.
    public static var dynamicNSColor: NSColor {
        NSColor(name: "cmuxAccent") { appearance in
            nsColor(for: appearance)
        }
    }

    /// SwiftUI accent that follows the view's color scheme.
    public static var color: Color {
        Color(nsColor: dynamicNSColor)
    }

    /// Color for a sidebar status entry's hex. The built-in agent status blue
    /// resolves to the accent; any other valid hex is used as written.
    public static func statusEntryColor(
        hex: String?,
        isDark: Bool,
        mode: CmuxAccentColorMode = .stored()
    ) -> NSColor? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(builtInAgentStatusHex) == .orderedSame {
            return nsColor(isDark: isDark, mode: mode)
        }
        return NSColor(hex: trimmed)
    }

    private static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// `controlAccentColor` resolved to a concrete sRGB color for the scheme,
    /// so layer colors and hex conversions see the current system accent.
    private static func systemAccent(isDark: Bool) -> NSColor {
        let accent = NSColor.controlAccentColor
        guard let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) else {
            return accent.usingColorSpace(.sRGB) ?? accent
        }
        var resolved = accent
        appearance.performAsCurrentDrawingAppearance {
            resolved = accent.usingColorSpace(.sRGB) ?? accent
        }
        return resolved
    }
}
