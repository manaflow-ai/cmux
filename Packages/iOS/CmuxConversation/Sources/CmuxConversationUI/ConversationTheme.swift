#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Metrics and colors matched to iOS 26 Messages.
enum ConversationTheme {
    // MARK: Metrics (points)

    // MARK: Dynamic Type
    //
    // Messages sizes transcript text with the body style (ChatKit's
    // ShortBody): 14 pt at XS, 17 at Large, 21 at XXL, 40 at AX3. Metrics
    // given as Large values are scaled by the current content size category
    // at each read.

    /// `value` (a Large-size metric) at the current content size category.
    static func scaled(_ value: CGFloat, _ style: UIFont.TextStyle = .body) -> CGFloat {
        UIFontMetrics(forTextStyle: style).scaledValue(for: value)
    }

    /// A system font scaled like `style`. Bold Text needs nothing here: UIKit
    /// already returns the heavier face (.SFUI-Semibold for regular) when it
    /// is on, so bumping the weight again would double it.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body, maximum: CGFloat? = nil) -> UIFont {
        cachedFont(FontRequest(name: style.rawValue, size: size, weight: weight.rawValue, maximum: maximum ?? 0)) {
            var pointSize = scaled(size, style)
            if let maximum { pointSize = min(pointSize, maximum) }
            return .systemFont(ofSize: pointSize, weight: weight)
        }
    }

    // MARK: Font cache
    //
    // Cells read these fonts (and metrics derived from them) many times per
    // configure and layout pass; building a font from a text style is a
    // descriptor lookup each time. Fonts are cached on the main thread per
    // Dynamic Type size, Bold Text and legibility weight, so a change to
    // any of them produces fresh fonts exactly as before.

    private struct FontRequest: Hashable {
        var name: String
        var size: CGFloat = 0
        var weight: CGFloat = 0
        var maximum: CGFloat = 0
    }

    private struct FontEnvironment: Equatable {
        var appCategory: UIContentSizeCategory
        var currentCategory: UIContentSizeCategory
        var legibility: UILegibilityWeight
        var boldText: Bool
    }

    nonisolated(unsafe) private static var fontCache: [FontRequest: UIFont] = [:]
    nonisolated(unsafe) private static var fontCacheEnvironment: FontEnvironment?

    private static func cachedFont(_ request: FontRequest, make: () -> UIFont) -> UIFont {
        guard Thread.isMainThread else { return make() }
        let environment = MainActor.assumeIsolated {
            let current = UITraitCollection.current
            return FontEnvironment(
                appCategory: UIApplication.shared.preferredContentSizeCategory,
                currentCategory: current.preferredContentSizeCategory,
                legibility: current.legibilityWeight,
                boldText: UIAccessibility.isBoldTextEnabled
            )
        }
        if environment != fontCacheEnvironment {
            fontCacheEnvironment = environment
            fontCache.removeAll()
        }
        if let font = fontCache[request] { return font }
        let font = make()
        fontCache[request] = font
        return font
    }

    /// Composer text: the bubble font, so a sent draft's glyphs fly into
    /// the bubble unchanged.
    static var bodyFont: UIFont { bubbleFont }
    static var bodyFontSize: CGFloat { bodyFont.pointSize }
    /// Composer line pitch: Messages steps the field by the bubble's line
    /// height (measured 20 pt per line at Large, same as a bubble line).
    static var lineHeight: CGFloat { bubbleFont.lineHeight }
    /// Text inset above and below in the composer field: the one-line field
    /// is 40.3 pt at Large, 47.7 at XXXL, 59.7 at AX2 (measured), i.e. the
    /// line plus about 10 pt on each side at every size.
    static let composerTextPadding: CGFloat = 10

    // Bubble metrics follow ChatKit's CKUIBehavior on iOS 26.3 and scale
    // with Dynamic Type the way Messages does.

    /// Bubble text: the body style with tight leading ("ShortBody"), 17 pt at
    /// the default size.
    static var bubbleFont: UIFont {
        cachedFont(FontRequest(name: "bubble")) {
            let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
            return UIFont(descriptor: descriptor.withSymbolicTraits(.traitTightLeading) ?? descriptor, size: 0)
        }
    }

    /// The accessibility text sizes start where body text reaches 28 pt.
    static var isAccessibilitySize: Bool { bubbleFont.pointSize >= 28 }

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
    /// Pixels per point of the screen the transcript is on: bubbles round up
    /// to its grid. Set by the conversation controller from its traits (main
    /// thread only); 3 until then, every current iPhone Pro.
    nonisolated(unsafe) static var displayScale: CGFloat = 3

    /// The narrowest text bubble.
    static let minBubbleWidth: CGFloat = 48

    /// At accessibility sizes ChatKit drops the 85% cap: the bubble column is
    /// the transcript width less both margins and 23.33 pt (346.7 on a 402 pt
    /// transcript with 16 pt margins, 376.7 on 440/20), at every AX size.
    static let accessibilityBubbleInset: CGFloat = 70.0 / 3.0

    /// Widest bubble for `width` of transcript between the side margins:
    /// ChatKit's balloon max width (280.67 pt on a 402 pt phone, 310.67 on
    /// 440; iOS 26.5 and 27.0), or the full width less
    /// `accessibilityBubbleInset` at the accessibility sizes.
    static func maxBubbleWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        isAccessibilitySize ? width - accessibilityBubbleInset : ConversationTranscriptMetrics.balloonMaxWidth(betweenMargins: width)
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
    /// A row grows this much when its first tapback lands (measured on iOS
    /// 26 Messages); the badge sits in that space above the bubble.
    static let reactionRowGrowth: CGFloat = 33
    /// A lone emoji shows at 72 pt, two or three at 48 pt.
    static let singleEmojiFontSize: CGFloat = 72
    static let emojiOnlyFontSize: CGFloat = 48
    /// ChatKit's sizes at Large, scaled with Dynamic Type like body text.
    static func emojiOnlyFontSize(count: Int) -> CGFloat { scaled(count == 1 ? singleEmojiFontSize : emojiOnlyFontSize) }
    static let maxImageWidthFraction: CGFloat = 0.63
    /// Measured: a 9:16 photo in Messages (iPhone 17 Pro) stops at 337 pt.
    static let maxImageHeight: CGFloat = 337

    /// Group sender names: caption 2 (11 pt at the default size), 14 pt in
    /// from the bubble's leading edge.
    static var senderNameFont: UIFont { cachedFont(FontRequest(name: "sender")) { .preferredFont(forTextStyle: .caption2) } }
    static let senderNameInset: CGFloat = 14
    /// "Delivered"/"Read": caption 2 semibold (11 pt, 13.33 pt tall at Large;
    /// Messages scales it: 20.3 pt tall at XXXL, 48 at AX5), 6 pt under the
    /// body and 20 pt in from its trailing edge.
    static var footerFont: UIFont { font(11, .semibold, style: .caption2) }
    static var footerDetailFont: UIFont { font(11, style: .caption2) }
    static var footerHeight: CGFloat { scaled(40.0 / 3, .caption2) }
    static let footerGap: CGFloat = 6
    static let footerInset: CGFloat = 20
    static var editedFont: UIFont { font(11, style: .caption2) }
    /// Reply quote text: subheadline, 15 pt at the default size.
    static var quoteFont: UIFont { cachedFont(FontRequest(name: "quote")) { .preferredFont(forTextStyle: .subheadline) } }
    /// Status, separators and swipe times are 11 pt caption 2 in Messages (iOS 26).
    static var timestampFont: UIFont { font(11, style: .caption2) }
    /// ChatKit's `transcriptBoldFont`: "Today" in separators, names in
    /// status lines and the service in the header are medium, not semibold
    /// (iOS 26.5 and 27.0).
    static var timestampBoldFont: UIFont { font(11, .medium, style: .caption2) }
    /// Swipe-left send times: the timestamp size with tabular digits, as
    /// ChatKit's `transcriptDrawerFont` (monospaced digits, iOS 26 and 27).
    static var timestampDrawerFont: UIFont {
        cachedFont(FontRequest(name: "drawer")) { .monospacedDigitSystemFont(ofSize: timestampFont.pointSize, weight: .regular) }
    }
    /// Separator, swipe-time and status gray: Messages draws these in the
    /// system secondary label color (138,138,142 on white).
    static let timestampText = UIColor { traits in
        if traits.isOverConversationBackdrop { return backdropCaption(traits) }
        return UIColor.secondaryLabel.resolvedColor(with: traits)
    }

    /// Captions straight over a conversation background (timestamps, status,
    /// system lines): ChatKit overrides their gray (`overrideTextColor`) so
    /// they stay legible on any color; near-white or near-black by the
    /// background's derived style. Not sampled from Messages.
    static func backdropCaption(_ traits: UITraitCollection) -> UIColor {
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: high ? 1 : 0.86)
            : UIColor(white: 0, alpha: high ? 0.95 : 0.74)
    }

    /// Composer metrics.
    static let composerSideInset: CGFloat = ComposerBarGeometry.restSideInset
    static let plusButtonSize: CGFloat = 40
    static let composerFieldGap: CGFloat = ComposerBarGeometry.plusToFieldGap
    /// One line plus `composerTextPadding` above and below (40.3 pt at Large).
    static var composerMinHeight: CGFloat { lineHeight + 2 * composerTextPadding }

    // MARK: Colors

    /// iMessage blue. iOS 26 tints it slightly brighter in dark mode.
    static let outgoingBubble = UIColor { traits in
        // Increase Contrast: ChatKit's blue goes flat and darker (sampled
        // 0,105,233 light / 0,98,219 dark).
        guard traits.accessibilityContrast == .high else { return UIColor.systemBlue.resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark
            ? UIColor(red: 0, green: 98 / 255, blue: 219 / 255, alpha: 1)
            : UIColor(red: 0, green: 105 / 255, blue: 233 / 255, alpha: 1)
    }

    static let incomingBubble = UIColor { traits in
        if traits.accessibilityContrast == .high {
            // ChatKit's high-contrast gray (CKBalloonShapeLayer fill).
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.188, green: 0.188, blue: 0.201, alpha: 1)
                : UIColor(red: 0.873, green: 0.873, blue: 0.880, alpha: 1)
        }
        return traits.userInterfaceStyle == .dark
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
            // Increase Contrast: Messages' blue goes flat (no gradient).
            if traits.accessibilityContrast == .high {
                let flat = ConversationTheme.outgoingBubble.resolvedColor(with: traits).cgColor
                return ([flat, flat], [0, 1])
            }
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

    /// Contacts' monogram for people without a photo (CNAvatarImageRenderer
    /// on iOS 26.3): a periwinkle gradient, top to bottom, the same in dark
    /// mode, with white semibold initials at 0.47 of the diameter.
    static let monogramGradient = [
        UIColor(red: 169 / 255, green: 194 / 255, blue: 226 / 255, alpha: 1),
        UIColor(red: 115 / 255, green: 127 / 255, blue: 185 / 255, alpha: 1),
    ]
    static let monogramFontScale: CGFloat = 0.472

    static let failedBubble = outgoingBubble

    static let outgoingText = UIColor.white
    static let incomingText = UIColor.label
    static let background = UIColor.systemBackground
    static let secondaryText = UIColor { traits in
        if traits.isOverConversationBackdrop { return backdropCaption(traits) }
        // Increase Contrast: Messages' captions use the system's high-contrast
        // secondary label (99,99,105 on white, measured).
        if traits.accessibilityContrast == .high { return UIColor.secondaryLabel.resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark
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
        if isAccessibilitySize { style.hyphenationFactor = 1 }
        return style
    }

    /// A fixed line height puts its extra space above the glyphs; frames shift up by this to center them.
    static var bodyGlyphLift: CGFloat { ((lineHeight - bodyFont.lineHeight) / 2).rounded(.down) }

    /// Bubble text paragraph: natural line height, word wrapping; at
    /// accessibility sizes Messages hyphenates long words ("din-ner").
    static var bubbleParagraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        if isAccessibilitySize { style.hyphenationFactor = 1 }
        return style
    }

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
