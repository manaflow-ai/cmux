#if canImport(UIKit)
import UIKit

extension UIColor {
    var terminalReadableForeground: UIColor {
        terminalPrefersDarkForeground ? .black : .white
    }

    var terminalPrefersDarkForeground: Bool {
        let whiteContrast = 1.05 / (terminalRelativeLuminance + 0.05)
        let blackContrast = (terminalRelativeLuminance + 0.05) / 0.05
        return blackContrast > whiteContrast
    }

    var terminalRelativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)
        let channels = [red, green, blue].map { channel in
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
#endif
