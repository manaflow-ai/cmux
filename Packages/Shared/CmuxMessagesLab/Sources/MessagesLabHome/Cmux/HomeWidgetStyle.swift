import CmuxHomeRender
import CoreGraphics
import Foundation

/// Fonts and colors of chat widget cards, from the transcript's palette (light and dark follow
/// `Fixture.lightAppearance`, like every other bubble).
struct HomeWidgetStyle {
    static let headlineFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    static let bodyFont = Fixture.bodyFont
    static let captionFont = UIFont.systemFont(ofSize: 11)
    static let rowTitleFont = UIFont.systemFont(ofSize: 13, weight: .medium)
    static let rowSubtitleFont = UIFont.systemFont(ofSize: 11)
    static let buttonFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let badgeFont = UIFont.systemFont(ofSize: 11, weight: .medium)

    static func font(_ style: HomeWidgetSnapshot.TextStyle) -> UIFont {
        switch style {
        case .headline: headlineFont
        case .body: bodyFont
        case .caption: captionFont
        }
    }

    static func lineHeight(_ style: HomeWidgetSnapshot.TextStyle) -> CGFloat {
        switch style {
        case .headline, .body: Fixture.lineHeight
        case .caption: 14
        }
    }

    static func color(_ tint: HomeWidgetSnapshot.Tint) -> UIColor {
        let light = Fixture.lightAppearance
        switch tint {
        case .primary: return Fixture.incomingText
        case .secondary: return Fixture.secondaryText
        case .accent: return Fixture.incomingLink
        case .success: return light ? UIColor(red: 0.16, green: 0.62, blue: 0.29, alpha: 1) : UIColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
        case .warning: return light ? UIColor(red: 0.85, green: 0.5, blue: 0, alpha: 1) : UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)
        case .danger: return light ? UIColor(red: 0.85, green: 0.19, blue: 0.15, alpha: 1) : UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
        }
    }

    /// A subtle fill on the bubble (secondary buttons, badges): the text color at low alpha.
    static func wash(_ color: UIColor, _ alpha: CGFloat = 0.12) -> UIColor { color.withAlphaComponent(alpha) }
}
