import CMUXMobileCore
import UIKit

extension TerminalTheme {
    var terminalBackgroundUIColor: UIColor {
        guard let rgb = Self.rgbComponents(background) else { return .systemBackground }
        return UIColor(
            red: CGFloat(rgb.red) / 255.0,
            green: CGFloat(rgb.green) / 255.0,
            blue: CGFloat(rgb.blue) / 255.0,
            alpha: 1.0
        )
    }

    var terminalCursorUIColor: UIColor {
        guard let rgb = Self.rgbComponents(cursor) else { return .label }
        return UIColor(
            red: CGFloat(rgb.red) / 255.0,
            green: CGFloat(rgb.green) / 255.0,
            blue: CGFloat(rgb.blue) / 255.0,
            alpha: 1.0
        )
    }
}
