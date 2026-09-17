#if canImport(UIKit)
import CMUXMobileCore
import UIKit

extension TerminalTheme {
    /// The theme background as an opaque UIKit color.
    public var terminalBackgroundUIColor: UIColor {
        background.terminalUIColor(fallback: TerminalTheme.monokai.background)
    }

    /// The theme foreground as an opaque UIKit color.
    public var terminalForegroundUIColor: UIColor {
        foreground.terminalUIColor(fallback: TerminalTheme.monokai.foreground)
    }

    /// The theme cursor as an opaque UIKit color.
    public var terminalCursorUIColor: UIColor {
        cursor.terminalUIColor(fallback: TerminalTheme.monokai.cursor)
    }
}

private extension String {
    func terminalUIColor(fallback: String) -> UIColor {
        guard let rgb = TerminalTheme.rgbComponents(self)
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
