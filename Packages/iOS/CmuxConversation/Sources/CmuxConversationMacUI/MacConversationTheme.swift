#if os(macOS)
import AppKit

/// Metrics and colors matched to macOS 26 Messages at the default text size.
enum MacConversationTheme {
    nonisolated(unsafe) static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let lineHeight: CGFloat = 17
    static let bubbleHorizontalPadding: CGFloat = 10.5
    /// (29 pt single-line body - 17 pt line) / 2.
    static let bubbleVerticalPadding: CGFloat = 6
    static let bubbleCornerRadius: CGFloat = 14.5
    static let tailWidth: CGFloat = 4
    static let tailDrop: CGFloat = 4.5
    /// Max bubble width as a fraction of the transcript width (wide windows cap it in points).
    static let maxBubbleWidthFraction: CGFloat = 0.66
    static let maxBubbleWidth: CGFloat = 520
    static let groupedSpacing: CGFloat = 2.5
    static let runSpacing: CGFloat = 12
    static let sideMargin: CGFloat = 14
    static let avatarSize: CGFloat = 24
    static let avatarGap: CGFloat = 6
    static let emojiOnlyFontSize: CGFloat = 36
    static let maxImageWidth: CGFloat = 300
    static let maxImageHeight: CGFloat = 300
    static let reactionBadgeSize: CGFloat = 24

    nonisolated(unsafe) static let senderNameFont = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let footerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated(unsafe) static let editedFont = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let timestampFont = NSFont.systemFont(ofSize: 11)
    nonisolated(unsafe) static let timestampBoldFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static let outgoingBubble = NSColor.systemBlue
    static let incomingBubble = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.231, green: 0.231, blue: 0.239, alpha: 1)
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
    static let background = NSColor.textBackgroundColor

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
#endif
