#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Metrics and colors matched to iOS 26 Messages.
enum ConversationTheme {
    // MARK: Metrics (points)

    /// Composer text (the composer keeps its own fixed metrics).
    static let bodyFont = UIFont.systemFont(ofSize: 17)
    static var bodyFontSize: CGFloat { bodyFont.pointSize }
    /// Composer line pitch.
    static let lineHeight: CGFloat = 24

    // Bubble metrics follow ChatKit's CKUIBehavior on iOS 26.3 and scale
    // with Dynamic Type the way Messages does.

    /// Bubble text: the body style with tight leading ("ShortBody"), 17 pt at
    /// the default size.
    static var bubbleFont: UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFont(descriptor: descriptor.withSymbolicTraits(.traitTightLeading) ?? descriptor, size: 0)
    }

    /// The accessibility text sizes start where body text reaches 28 pt.
    private static var isAccessibilitySize: Bool { bubbleFont.pointSize >= 28 }

    /// Text inset inside the bubble body: 10/14 pt, 12/16.67 pt at the
    /// accessibility sizes.
    static var bubbleVerticalPadding: CGFloat { isAccessibilitySize ? 12 : 10 }
    static var bubbleHorizontalPadding: CGFloat { isAccessibilitySize ? 50.0 / 3 : 14 }

    /// Half a single-line bubble's height (20.14 pt at the default size), so
    /// one-line bubbles are pills and taller ones keep the same corners.
    static var bubbleCornerRadius: CGFloat { (bubbleFont.lineHeight + 2 * bubbleVerticalPadding) / 2 }

    /// iOS 26 tails sit inside the body's width.
    static let tailWidth: CGFloat = 0
    /// How far the tail drops below the bubble body (6.83 pt at the default size).
    static var tailDrop: CGFloat { ConversationBubbleGeometry.iOSTailDrop(radius: bubbleCornerRadius) }
    /// The narrowest text bubble.
    static let minBubbleWidth: CGFloat = 48

    /// Widest bubble for `width` of transcript between the side margins:
    /// 85%, or the full width less 23.3 pt at the accessibility sizes.
    static func maxBubbleWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        isAccessibilitySize ? width - 70.0 / 3 : width * 0.85
    }

    /// Body-to-body gap between bubbles in a run (`balloonContiguousSpace`).
    static let groupedSpacing: CGFloat = 4
    /// Body-to-body gap between runs (`balloonNonContiguousSpace`); a tail
    /// hangs into it.
    static let ungroupedSpacing: CGFloat = 10
    static let avatarSize: CGFloat = 32
    static let avatarGap: CGFloat = 7
    /// A timestamp separates messages this far apart.
    static let timestampGap: TimeInterval = 60 * 60
    static let reactionBadgeSize: CGFloat = 32
    /// A lone emoji shows at 72 pt, two or three at 48 pt.
    static let singleEmojiFontSize: CGFloat = 72
    static let emojiOnlyFontSize: CGFloat = 48
    static func emojiOnlyFontSize(count: Int) -> CGFloat { count == 1 ? singleEmojiFontSize : emojiOnlyFontSize }
    static let maxImageWidthFraction: CGFloat = 0.63
    static let maxImageHeight: CGFloat = 340

    /// Group sender names: caption 2 (11 pt at the default size), 14 pt in
    /// from the bubble's leading edge.
    static var senderNameFont: UIFont { .preferredFont(forTextStyle: .caption2) }
    static let senderNameInset: CGFloat = 14
    /// "Delivered"/"Read": 11 pt semibold, 13.33 pt tall, 6 pt under the body
    /// and 20 pt in from its trailing edge.
    static let footerFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
    static let footerHeight: CGFloat = 40.0 / 3
    static let footerGap: CGFloat = 6
    static let footerInset: CGFloat = 20
    static let editedFont = UIFont.systemFont(ofSize: 11, weight: .regular)
    /// Reply quote text: subheadline, 15 pt at the default size.
    static var quoteFont: UIFont { .preferredFont(forTextStyle: .subheadline) }
    static let timestampFont = UIFont.systemFont(ofSize: 12, weight: .regular)
    static let timestampBoldFont = UIFont.systemFont(ofSize: 12, weight: .semibold)

    /// Composer metrics.
    static let composerSideInset: CGFloat = 27
    static let plusButtonSize: CGFloat = 40
    static let composerFieldGap: CGFloat = 13
    static let composerMinHeight: CGFloat = 42

    // MARK: Colors

    /// iMessage blue. iOS 26 tints it slightly brighter in dark mode.
    static let outgoingBubble = UIColor.systemBlue

    static let incomingBubble = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 41 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    }

    /// Messages fills outgoing bubbles from a gradient fixed to the screen:
    /// lighter near the top, the plain service color at the bottom. Stops
    /// sampled from ChatKit's iMessage balloon on iOS 26.3 (sRGB).
    struct ScreenGradient: Sendable {
        var light: [(CGFloat, CGFloat, CGFloat)]
        var dark: [(CGFloat, CGFloat, CGFloat)]

        /// Colors and locations covering window fractions `top...bottom`.
        func samples(from top: CGFloat, to bottom: CGFloat, traits: UITraitCollection) -> (colors: [CGColor], locations: [CGFloat]) {
            let stops = traits.userInterfaceStyle == .dark ? dark : light
            func color(at fraction: CGFloat) -> CGColor {
                let f = max(0, min(1, fraction)) * CGFloat(stops.count - 1)
                let i = min(Int(f), stops.count - 2)
                let t = f - CGFloat(i)
                let a = stops[i], b = stops[i + 1]
                return UIColor(
                    red: (a.0 + (b.0 - a.0) * t) / 255,
                    green: (a.1 + (b.1 - a.1) * t) / 255,
                    blue: (a.2 + (b.2 - a.2) * t) / 255,
                    alpha: 1
                ).cgColor
            }
            guard bottom > top else { return ([color(at: top), color(at: top)], [0, 1]) }
            var fractions = [top]
            let step = 1 / CGFloat(stops.count - 1)
            var stop = (top / step).rounded(.down) * step + step
            while stop < bottom {
                fractions.append(stop)
                stop += step
            }
            fractions.append(bottom)
            return (fractions.map(color(at:)), fractions.map { ($0 - top) / (bottom - top) })
        }
    }

    static let iMessageGradient = ScreenGradient(
        light: [(90, 200, 250), (72, 184, 251), (52, 168, 252), (30, 152, 254), (0, 136, 255)],
        dark: [(64, 156, 255), (52, 153, 255), (37, 150, 255), (22, 148, 255), (0, 145, 255)]
    )

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
    nonisolated(unsafe) static let bodyParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    /// A fixed line height puts its extra space above the glyphs; frames shift up by this to center them.
    static var bodyGlyphLift: CGFloat { ((lineHeight - bodyFont.lineHeight) / 2).rounded(.down) }

    /// Bubble text paragraph: natural line height, word wrapping.
    nonisolated(unsafe) static let bubbleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style
    }()

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
