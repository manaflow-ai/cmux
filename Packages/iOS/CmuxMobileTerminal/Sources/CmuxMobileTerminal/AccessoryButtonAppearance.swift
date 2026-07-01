import UIKit

/// Builds terminal accessory button configurations for glass and flat keycap styles.
struct AccessoryButtonAppearance {
    let normalBackground: UIColor
    let cornerRadius: CGFloat

    init(
        normalBackground: UIColor = UIColor(white: 0.35, alpha: 1),
        cornerRadius: CGFloat = 6
    ) {
        self.normalBackground = normalBackground
        self.cornerRadius = cornerRadius
    }

    func configuration(
        armed: Bool,
        sticky: Bool,
        useLiquidGlass: Bool
    ) -> UIButton.Configuration {
        if #available(iOS 26.0, *), useLiquidGlass {
            var config: UIButton.Configuration = (armed || sticky) ? .prominentGlass() : .glass()
            config.baseForegroundColor = .white
            if armed || sticky {
                config.baseBackgroundColor = .systemBlue
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
            background.backgroundColor = normalBackground
        }
        background.cornerRadius = cornerRadius
        config.background = background
        config.baseForegroundColor = .white
        return config
    }
}
