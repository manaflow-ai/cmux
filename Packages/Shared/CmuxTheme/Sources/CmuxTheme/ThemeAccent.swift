import Foundation

/// Where the chrome's accent comes from (`appearance.accent`; the web module's `AppAccent`).
///
/// ``neutral`` (the default) is the foreground without hue. ``theme`` is the palette's
/// signature hue: magenta, else blue, else cyan, else neutral when the palette has no color.
/// A color name is that ANSI slot (the brighter of its normal and bright variants).
public enum ThemeAccent: String, CaseIterable, Hashable, Sendable {
    case neutral, theme, red, green, yellow, blue, magenta, cyan

    /// The ANSI slot of a named accent (its bright variant is 8 higher); nil for neutral and theme.
    var slot: Int? {
        switch self {
        case .neutral, .theme: nil
        case .red: 1
        case .green: 2
        case .yellow: 3
        case .blue: 4
        case .magenta: 5
        case .cyan: 6
        }
    }
}
