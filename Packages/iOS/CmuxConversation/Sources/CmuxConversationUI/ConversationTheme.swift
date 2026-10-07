#if canImport(UIKit)
import UIKit

/// Metrics and colors matched to iOS 26 Messages.
enum ConversationTheme {
    // MARK: Metrics (points)

    // MARK: Dynamic Type
    //
    // Messages sizes transcript text with the body style (ChatKit's
    // ShortBody): 14 pt at XS, 17 at Large, 21 at XXL, 40 at AX3, and the
    // bubble's corner grows with it. Metrics below are the Large values,
    // scaled by the current content size category at each read.

    /// `value` (a Large-size metric) at the current content size category.
    static func scaled(_ value: CGFloat, _ style: UIFont.TextStyle = .body) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: value)
    }

    /// A system font scaled like `style`, a weight step heavier with Bold Text.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body, maximum: CGFloat? = nil) -> UIFont {
        var pointSize = scaled(size, style)
        if let maximum { pointSize = min(pointSize, maximum) }
        return .systemFont(ofSize: pointSize, weight: UIAccessibility.isBoldTextEnabled ? boldTextWeight(weight) : weight)
    }

    private static func boldTextWeight(_ weight: UIFont.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight, .thin, .light: return .regular
        case .regular: return .semibold
        case .medium, .semibold: return .bold
        default: return .heavy
        }
    }

    /// Accessibility sizes widen the bubble column (ChatKit: max width 314.5
    /// at Large and up to XXXL, 346.7 at AX3 on a 402 pt transcript).
    static var maxWidthBoost: CGFloat {
        // Body reaches 28 pt at the first accessibility size.
        scaled(17) >= 28 ? 1.1023 : 1
    }

    static var bodyFont: UIFont { font(17) }
    static var bodyFontSize: CGFloat { bodyFont.pointSize }
    /// Line pitch inside bubbles and the composer (measured 24 pt at Large).
    static var lineHeight: CGFloat { ceil(scaled(24)) }
    static let bubbleHorizontalPadding: CGFloat = 14.5
    /// (44 pt single-line body - 24 pt line) / 2.
    static let bubbleVerticalPadding: CGFloat = 10
    static var bubbleCornerRadius: CGFloat { scaled(19) }
    /// Width the tail adds beyond the bubble body.
    static let tailWidth: CGFloat = 5
    /// Max bubble width as a fraction of the view width.
    static let maxBubbleWidthFraction: CGFloat = 0.715
    static let groupedSpacing: CGFloat = 6
    /// Tail bottom to the next run's first row (measured 24.7 pt).
    static let ungroupedSpacing: CGFloat = 25
    /// How far the tail drops below the bubble body.
    static let tailDrop: CGFloat = 7
    static let avatarSize: CGFloat = 32
    static let avatarGap: CGFloat = 7
    /// A timestamp separates messages this far apart.
    static let timestampGap: TimeInterval = 60 * 60
    static let reactionBadgeSize: CGFloat = 32
    static var emojiOnlyFontSize: CGFloat { scaled(48) }
    static let maxImageWidthFraction: CGFloat = 0.63
    static let maxImageHeight: CGFloat = 340

    static var senderNameFont: UIFont { font(12.5, style: .caption2) }
    static var footerFont: UIFont { font(12, .semibold, style: .caption2) }
    static var editedFont: UIFont { font(12, style: .caption2) }
    static var timestampFont: UIFont { font(12, style: .caption2) }
    static var timestampBoldFont: UIFont { font(12, .semibold, style: .caption2) }
    static var quoteFont: UIFont { font(15, style: .subheadline) }

    /// Composer metrics.
    static let composerSideInset: CGFloat = 27
    static let plusButtonSize: CGFloat = 40
    static let composerFieldGap: CGFloat = 13
    /// One line plus 9 pt above and below (42 pt at Large).
    static var composerMinHeight: CGFloat { lineHeight + 18 }

    // MARK: Colors

    /// iMessage blue. iOS 26 tints it slightly brighter in dark mode.
    static let outgoingBubble = UIColor.systemBlue

    static let incomingBubble = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 33 / 255, blue: 38 / 255, alpha: 1)
            : UIColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    }

    static let failedBubble = UIColor.systemBlue

    static let outgoingText = UIColor.white
    static let incomingText = UIColor.label
    static let background = UIColor.systemBackground
    static let secondaryText = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 133 / 255, green: 132 / 255, blue: 136 / 255, alpha: 1)
            : UIColor(red: 124 / 255, green: 124 / 255, blue: 128 / 255, alpha: 1)
    }
    static let tertiaryText = UIColor.tertiaryLabel
    static let notDelivered = UIColor.systemRed
    static let replyThread = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.28)
            : UIColor(white: 0, alpha: 0.18)
    }

    static let quoteStroke = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.30)
            : UIColor(white: 0, alpha: 0.22)
    }

    static let badgeFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 33 / 255, blue: 30 / 255, alpha: 1)
            : UIColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)
    }

    /// Body paragraph with the measured 24 pt pitch, glyphs vertically centered in the line.
    static var bodyParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        // At accessibility sizes Messages hyphenates long words ("din-ner").
        if maxWidthBoost > 1 { style.hyphenationFactor = 1 }
        return style
    }

    /// A fixed line height puts its extra space above the glyphs; frames shift up by this to center them.
    static var bodyGlyphLift: CGFloat { ((lineHeight - bodyFont.lineHeight) / 2).rounded(.down) }

    static func color(hex: String) -> UIColor {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A glass surface on iOS 26, a material blur before it.
@MainActor
func makeGlassView(cornerRadius: CGFloat, interactive: Bool = false, tint: UIColor? = nil) -> UIVisualEffectView {
    let view: UIVisualEffectView
    if #available(iOS 26.0, *) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = interactive
        effect.tintColor = tint
        view = UIVisualEffectView(effect: effect)
    } else {
        view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
}
#endif
