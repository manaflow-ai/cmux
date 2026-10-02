#if os(macOS)
import AppKit

/// Metrics and colors matched to macOS 26 Messages at the default text size.
enum MacConversationTheme {
    // Measured from macOS 26 Messages at the default text size (2x capture).
    nonisolated(unsafe) static let bodyFont = NSFont.systemFont(ofSize: 13)
    /// Measured: 18 pt between lines of a multi-line Messages bubble.
    static let lineHeight: CGFloat = 18
    /// Text inset from the bubble edge (measured 11.5 to 12).
    static let bubbleHorizontalPadding: CGFloat = 12
    /// (32 pt single-line body - 18 pt line) / 2.
    static let bubbleVerticalPadding: CGFloat = 7
    /// The 18 pt line puts its extra leading above the glyphs, so the text box
    /// rides 2 pt high to land Messages' ink 10 pt from the bubble top.
    static let bubbleTextLift: CGFloat = 2
    static let bubbleCornerRadius: CGFloat = 17
    /// macOS tails tuck under the corner, so they add no width.
    static let tailWidth: CGFloat = 0
    static let tailDrop: CGFloat = 5
    /// Widest observed bubble: 680 of a 1087 pt transcript.
    static let maxBubbleWidthFraction: CGFloat = 0.625
    static let maxBubbleWidth: CGFloat = 10_000
    static let groupedSpacing: CGFloat = 3
    static let runSpacing: CGFloat = 12
    /// Incoming avatar column starts 20 pt in; outgoing bodies end 21 pt in.
    static let sideMargin: CGFloat = 20
    static let outgoingMargin: CGFloat = 20.5
    static let avatarSize: CGFloat = 25
    static let avatarGap: CGFloat = 10
    static let senderNameInset: CGFloat = 12
    static let emojiOnlyFontSize: CGFloat = 36
    static let maxImageWidth: CGFloat = 260
    static let maxImageHeight: CGFloat = 330
    static let reactionBadgeSize: CGFloat = 24

    nonisolated(unsafe) static let senderNameFont = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let footerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let editedFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let timestampFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let timestampBoldFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    /// Dark: Display P3 (67, 145, 247), matched by rendering swatches on the same
    /// display as Messages (it is outside sRGB); independent of the accent color.
    static let outgoingBubble = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(displayP3Red: 67 / 255, green: 145 / 255, blue: 247 / 255, alpha: 1)
            : NSColor(srgbRed: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1)
    }
    static let incomingBubble = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 58 / 255, green: 59 / 255, blue: 62 / 255, alpha: 1)
            : NSColor(srgbRed: 0.914, green: 0.914, blue: 0.922, alpha: 1)
    }
    static let badgeFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.27, green: 0.27, blue: 0.28, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 1)
    }
    static let quoteStroke = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.28)
            : NSColor(white: 0, alpha: 0.2)
    }
    static let threadLine = quoteStroke
    static let outgoingText = NSColor.white
    static let incomingText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    /// Dark: sRGB (30, 30, 30), matched on the same display as Messages.
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
            : NSColor.white
    }

    nonisolated(unsafe) static let bodyParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }()
}

/// Resolves a dynamic color for a view's current appearance.
@MainActor
func resolved(_ color: NSColor, in view: NSView) -> CGColor {
    var result = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        result = color.cgColor
    }
    return result
}

extension NSAppearance {
    var isDarkMac: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
#endif
