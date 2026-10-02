public import CoreGraphics

/// Sizes the transcript lays out with (points). Resolved on the main actor
/// from the Metrics and Typography tokens (`TranscriptGeometry.current`), then
/// passed by value to background measurement and rasterization.
nonisolated struct TranscriptGeometry: Hashable, Sendable {
    var width: CGFloat
    var fontSize: CGFloat
    var captionSize: CGFloat
    var insetX: CGFloat
    var insetY: CGFloat
    var sideMargin: CGFloat
    var groupGap: CGFloat
    var senderGap: CGFloat
    var labelGap: CGFloat
    var badgeRoom: CGFloat
    var tailWidth: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var separatorHeight: CGFloat
    var labelHeight: CGFloat
    var typingHeight: CGFloat
    var workCardWidth: CGFloat
    /// Widest text line in a bubble; quantized so a resize re-measures only
    /// when it crosses an 8 pt step.
    var maxTextWidth: CGFloat

    static let groupWindow: Double = 60
    static let separatorWindow: Double = 15 * 60
    static let maxTextCap: CGFloat = 440
    static let bubbleFraction: CGFloat = 0.72

    /// The geometry at `width` with the given tokens.
    static func make(width: CGFloat, fontSize: CGFloat, captionSize: CGFloat, space: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat))
        -> TranscriptGeometry {
        let (s1, s2, s3, s4, s5, s6) = space
        let insetX = s5
        let margin = s6
        let available = max(80, (width - 2 * margin) * bubbleFraction - 2 * insetX)
        let quantized = (min(maxTextCap, available) / 8).rounded(.down) * 8
        let line = (fontSize * 1.25).rounded(.up)
        return TranscriptGeometry(
            width: width, fontSize: fontSize, captionSize: captionSize, insetX: insetX, insetY: s3, sideMargin: margin,
            groupGap: s1, senderGap: s4 + s2, labelGap: s2, badgeRoom: s5, tailWidth: s3,
            topPadding: s6, bottomPadding: s4, separatorHeight: (captionSize * 1.3).rounded(.up) + 2 * s5,
            labelHeight: (captionSize * 1.3).rounded(.up) + s1, typingHeight: line + 2 * s3,
            workCardWidth: min(quantized + 2 * insetX, 18 * fontSize + 2 * insetX), maxTextWidth: max(64, quantized))
    }

    var lineHeight: CGFloat { (fontSize * 1.25).rounded(.up) }
    var captionLineHeight: CGFloat { (captionSize * 1.3).rounded(.up) }
    var maxBubbleWidth: CGFloat { maxTextWidth + 2 * insetX }
    var bubbleRadius: CGFloat { (lineHeight + 2 * insetY) / 2 }

    func bubbleX(width bubble: CGFloat, outgoing: Bool) -> CGFloat {
        outgoing ? width - sideMargin - bubble : sideMargin
    }

    /// Height of a work card: session line, preview line, insets.
    var workCardHeight: CGFloat { 2 * insetY + lineHeight + captionLineHeight }
}
