#if os(macOS)
import AppKit
import CmuxConversationGeometry

/// Metrics and colors matched to macOS 26 Messages at the default text size.
enum MacConversationTheme {
    // Measured from macOS 26 Messages at the default text size (2x capture).
    // The transcript metrics below scale with View > Make Text Bigger /
    // Smaller (`textScale`); at the default size they are the measured values.
    static let defaultBodyFontSize: CGFloat = 13
    /// The transcript's body size over Messages' default (View > Make Text
    /// Bigger / Smaller). Set through `MacConversationTextSize`.
    nonisolated(unsafe) private(set) static var textScale: CGFloat = MacConversationTextSize.storedSize() / defaultBodyFontSize
    nonisolated(unsafe) private(set) static var bodyFont = NSFont.systemFont(ofSize: defaultBodyFontSize * textScale)
    /// Measured: 18 pt between lines of a multi-line Messages bubble.
    static var lineHeight: CGFloat { (18 * textScale).rounded() }
    /// Text inset from the bubble edge (measured 11.5 to 12).
    static var bubbleHorizontalPadding: CGFloat { 12 * textScale }
    /// (32 pt single-line body - 18 pt line) / 2.
    static var bubbleVerticalPadding: CGFloat { 7 * textScale }
    /// The 18 pt line puts its extra leading above the glyphs, so the text box
    /// rides 2 pt high to land Messages' ink 10 pt from the bubble top.
    static var bubbleTextLift: CGFloat { 2 * textScale }
    /// ChatKit's corner radius is half a single-line bubble (32 pt here).
    static var bubbleCornerRadius: CGFloat { (lineHeight + 2 * bubbleVerticalPadding) / 2 }
    /// The tail sits inside the body's width.
    static let tailWidth: CGFloat = 0
    static var tailDrop: CGFloat { ConversationBubbleGeometry.iOSTailDrop(radius: bubbleCornerRadius) }
    /// CKUIBehaviorMac: 65% of the transcript between its side margins
    /// (680 pt of a 1087 pt transcript).
    static let maxBubbleWidthFraction: CGFloat = 0.65
    static let maxBubbleWidth: CGFloat = 10_000
    static let groupedSpacing: CGFloat = 3
    static let runSpacing: CGFloat = 12
    /// Incoming avatar column starts 20 pt in; outgoing bodies end 21 pt in.
    static let sideMargin: CGFloat = 20
    static let outgoingMargin: CGFloat = 20.5
    static let avatarSize: CGFloat = 25
    static let avatarGap: CGFloat = 10
    static let senderNameInset: CGFloat = 12
    /// CKUIBehaviorMac: a lone emoji at 72 pt, two or three at 48 pt.
    static func emojiOnlyFontSize(count: Int) -> CGFloat { (count == 1 ? 72 : 48) * textScale }

    /// The composer keeps Messages' default metrics at every transcript size.
    nonisolated(unsafe) static let composerFont = NSFont.systemFont(ofSize: defaultBodyFontSize)
    static let composerLineHeight: CGFloat = 18
    nonisolated(unsafe) static let composerParagraph: NSParagraphStyle = paragraph(lineHeight: composerLineHeight)

    /// Applies a transcript body size (`MacConversationTextSize` persists it).
    static func setBodyFontSize(_ size: CGFloat) {
        textScale = size / defaultBodyFontSize
        bodyFont = NSFont.systemFont(ofSize: size)
        bodyParagraph = paragraph(lineHeight: lineHeight)
    }

    static func paragraph(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static let maxImageWidth: CGFloat = 260
    static let maxImageHeight: CGFloat = 330
    static let reactionBadgeSize: CGFloat = 24

    /// Measured: "Austin Wang" inks 58.5 pt wide in Messages, 10 pt regular.
    nonisolated(unsafe) static let senderNameFont = NSFont.systemFont(ofSize: 10)
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

    static let quoteLineHeight: CGFloat = 13
    nonisolated(unsafe) static let quoteAttributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = quoteLineHeight
        style.maximumLineHeight = quoteLineHeight
        style.lineBreakMode = .byWordWrapping
        return [.font: NSFont.systemFont(ofSize: 10), .paragraphStyle: style]
    }()

    nonisolated(unsafe) private(set) static var bodyParagraph: NSParagraphStyle = paragraph(lineHeight: lineHeight)
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
