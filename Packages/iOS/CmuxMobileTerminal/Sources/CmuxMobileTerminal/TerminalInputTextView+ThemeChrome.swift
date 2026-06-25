import CMUXMobileCore
import Foundation
import UIKit

extension TerminalInputTextView {
    var themeBarColor: UIColor {
        guard let rgb = TerminalTheme.rgbComponents(terminalTheme.background) else {
            return UIColor(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0, alpha: 1)
        }
        return UIColor(red: CGFloat(rgb.red) / 255.0, green: CGFloat(rgb.green) / 255.0, blue: CGFloat(rgb.blue) / 255.0, alpha: 1)
    }

    var themeControlForegroundColor: UIColor {
        themeIsLight ? UIColor.black.withAlphaComponent(0.82) : UIColor.white.withAlphaComponent(0.88)
    }

    var themeControlFillColor: UIColor {
        themeIsLight ? UIColor.black.withAlphaComponent(0.08) : UIColor.white.withAlphaComponent(0.14)
    }

    var themeControlStrokeColor: UIColor {
        themeIsLight ? UIColor.black.withAlphaComponent(0.16) : UIColor.white.withAlphaComponent(0.20)
    }

    func applyPlainAccessoryControlStyle(_ button: UIButton) {
        var config = button.configuration ?? .plain()
        config.baseForegroundColor = themeControlForegroundColor
        button.configuration = config
        button.tintColor = themeControlForegroundColor
    }

    func accessoryButtonConfiguration(armed: Bool, sticky: Bool) -> UIButton.Configuration {
        if #available(iOS 26.0, *) {
            var config: UIButton.Configuration = (armed || sticky) ? .prominentGlass() : .glass()
            if armed || sticky {
                config.baseForegroundColor = .white
                config.baseBackgroundColor = .systemBlue
            } else {
                config.baseForegroundColor = themeControlForegroundColor
            }
            return config
        }
        var config = UIButton.Configuration.plain()
        var background = UIBackgroundConfiguration.clear()
        if sticky {
            background.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            background.strokeColor = .white
            background.strokeWidth = 2
        } else if armed {
            background.backgroundColor = .systemBlue
        } else {
            background.backgroundColor = themeControlFillColor
            background.strokeColor = themeControlStrokeColor
            background.strokeWidth = 1
        }
        background.cornerRadius = Self.accessoryButtonCornerRadius
        config.background = background
        config.baseForegroundColor = (armed || sticky) ? .white : themeControlForegroundColor
        return config
    }

    private var themeIsLight: Bool {
        guard let rgb = TerminalTheme.rgbComponents(terminalTheme.background) else { return false }
        func channel(_ value: Int) -> Double {
            let normalized = Double(value) / 255.0
            if normalized <= 0.03928 { return normalized / 12.92 }
            return pow((normalized + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
        return luminance > 0.55
    }
}
