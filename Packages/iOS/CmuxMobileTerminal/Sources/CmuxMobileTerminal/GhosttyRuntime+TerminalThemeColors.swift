#if canImport(UIKit)
import CMUXMobileCore
import UIKit

public extension GhosttyRuntime {
    /// Converts a terminal theme background into a UIKit color.
    /// - Parameter theme: The resolved terminal theme.
    /// - Returns: Its background as an opaque UIKit color.
    static func backgroundUIColor(for theme: TerminalTheme) -> UIColor {
        uiColor(theme.background, fallback: TerminalTheme.monokai.background)
    }

    /// Converts a terminal theme foreground into a UIKit color.
    /// - Parameter theme: The resolved terminal theme.
    /// - Returns: Its foreground as an opaque UIKit color.
    static func foregroundUIColor(for theme: TerminalTheme) -> UIColor {
        uiColor(theme.foreground, fallback: TerminalTheme.monokai.foreground)
    }

    /// Converts a terminal theme cursor into a UIKit color.
    /// - Parameter theme: The resolved terminal theme.
    /// - Returns: Its cursor as an opaque UIKit color.
    static func cursorUIColor(for theme: TerminalTheme) -> UIColor {
        uiColor(theme.cursor, fallback: TerminalTheme.monokai.cursor)
    }

    private static func uiColor(_ value: String, fallback: String) -> UIColor {
        guard let rgb = TerminalTheme.rgbComponents(value)
            ?? TerminalTheme.rgbComponents(fallback) else { return .white }
        return UIColor(
            red: CGFloat(rgb.red) / 255.0,
            green: CGFloat(rgb.green) / 255.0,
            blue: CGFloat(rgb.blue) / 255.0,
            alpha: 1
        )
    }
}
#endif
