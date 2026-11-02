import CoreGraphics

/// Transcript sizing rules read from ChatKit on iOS 26.5 and 27.0 (iPhone 17
/// Pro and Pro Max simulators, Large text), shared by every surface that
/// lays out bubbles.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationTranscriptMetrics {
    /// What ChatKit keeps free beside the widest balloon: `CKUIBehavior
    /// balloonMaxWidthForTranscriptWidth:` takes the transcript width less the
    /// entry view's content insets (the margins plus 107.33 pt), less the
    /// balloon's 5 pt line fragment insets, plus its 14 pt pill insets. That
    /// is the width between the margins less 89.33 pt: 280.67 on a 402 pt
    /// phone (370 between 16 pt margins), 310.67 on 440 (400 between 20 pt).
    public static let balloonWidthReserve: CGFloat = 268.0 / 3.0

    /// ChatKit's ceiling on that: 85% of the width between the margins
    /// (`balloonMaxWidthPercent`); it only binds above 595 pt.
    public static let balloonMaxWidthFraction: CGFloat = 0.85

    /// Widest balloon (tail area included, which is none on iOS 26 and 27)
    /// for `width` of transcript between the side margins, at the default
    /// and larger non-accessibility text sizes.
    public static func balloonMaxWidth(betweenMargins width: CGFloat) -> CGFloat {
        max(0, min(width - balloonWidthReserve, width * balloonMaxWidthFraction))
    }

    /// ChatKit sizes a balloon to its text and rounds the result up to the
    /// pixel grid: "Are we still on for dinner tonight?" is 249.70 pt of text
    /// in a 278.00 pt balloon (249.70 + 28 = 277.70, up to 278.00 at @3x), one
    /// 20.29 pt line in a 40.33 pt balloon.
    public static func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let s = scale > 0 ? scale : 1
        // A hair of tolerance so an exact pixel value (278.0000001) stays put.
        return ((value * s) - 0.001).rounded(.up) / s
    }

    /// ChatKit's outgoing gradient runs down its gradient reference view (the
    /// whole window) but ends `gradientBottomPlaceholderHeight` above the
    /// bottom: the resting entry view, 69 pt on Face ID iPhones (35 pt of bar
    /// over the 34 pt home indicator inset; 402 and 440 pt wide, iOS 26.5 and
    /// 27.0). Below that line bubbles keep the final color. Fitting Messages'
    /// bubble fills (light and dark, both widths) to this span recovers our
    /// stops within 1-3 levels; the full window height leaves them 2-6 off.
    public static let gradientEntryBarHeight: CGFloat = 35

    /// Height of the band the outgoing gradient spans, from the window's top.
    public static func gradientSpan(windowHeight: CGFloat, bottomSafeInset: CGFloat) -> CGFloat {
        max(1, windowHeight - bottomSafeInset - gradientEntryBarHeight)
    }

    // MARK: Spacing at every text size

    /// ChatKit's transcript spaces at Large: `balloonContiguousSpace` (between
    /// bubbles in a run), `balloonNonContiguousSpace` (between runs),
    /// `smallTranscriptSpace` (a bubble to its "Delivered"),
    /// `mediumTranscriptSpace` and `mediumLargeTranscriptSpace` (around a
    /// timestamp).
    public static let contiguousSpace: CGFloat = 4
    public static let nonContiguousSpace: CGFloat = 10
    public static let smallSpace: CGFloat = 6
    public static let mediumSpace: CGFloat = 10
    /// `selfReplyTranscriptSpace`: around an inline reply (its quote above,
    /// the next row below).
    public static let replyBlockSpace: CGFloat = 24
    public static let mediumLargeSpace: CGFloat = 16

    /// The caption 2 line spacing (line height plus leading) at Large, 13 pt
    /// (11 pt type), that ChatKit's spaces are drawn for.
    public static let referenceCaptionLineSpacing: CGFloat = 13

    /// The caption 2 line spacing that ChatKit's spaces scale with. With a
    /// tall-script language (Arabic, for one) among the reader's languages,
    /// iOS grows each text style font's line height (caption 2 13.13 ->
    /// 15.13 pt at Large); Messages' spaces ignore that growth (a run's
    /// bubbles stay 4 pt apart on a real iPhone set to en-US + ar), so the
    /// spacing uses the line height the same font has without it.
    public static func captionLineSpacing(lineHeight: CGFloat, leading: CGFloat, languageNeutralLineHeight: CGFloat) -> CGFloat {
        min(lineHeight, languageNeutralLineHeight) + leading
    }

    /// A group sender name above an incoming bubble: its line box is the
    /// caption line height rounded up to the pixel grid, and the bubble
    /// starts a run's space (`contiguousSpace`) under that box. Fitted to a
    /// real iPhone 17 Pro Max (iOS 26.4, en-US + ar): the name's cap top
    /// 15.67-16.0 pt above the bubble.
    public static func senderNameLine(lineHeight: CGFloat, captionLineSpacing: CGFloat, scale: CGFloat) -> (height: CGFloat, bubbleOffset: CGFloat) {
        let height = ceilToPixel(lineHeight, scale: scale)
        return (height, height + space(contiguousSpace, captionLineSpacing: captionLineSpacing, scale: scale))
    }

    /// Top of a group avatar beside the last bubble of an incoming run: its
    /// bottom meets the tip of the bubble's tail (`tailDrop` below the
    /// body), or the body's bottom when the bubble has no tail. Real iPhone
    /// 17 Pro Max (iOS 26.4): the avatar ends 7.67 pt under a one-line body.
    public static func avatarMinY(bodyBottom: CGFloat, tailDrop: CGFloat?, avatarSize: CGFloat) -> CGFloat {
        bodyBottom + (tailDrop ?? 0) - avatarSize
    }

    /// A transcript space at the reader's text size. ChatKit scales every
    /// space by the caption 2 font's line spacing over its 13 pt at Large and
    /// rounds to the pixel grid; up to Large nothing changes. Logged from
    /// `CKUIBehavior` on iOS 26.5 and 27.0: between runs 10, 14, 15.33, 17,
    /// 19.33, 22.33, 27 at Large, XL, XXL, XXXL, AX1, AX2, AX3 (caption line
    /// spacing 13, 18, 20, 22, 25, 29, 35).
    public static func space(_ base: CGFloat, captionLineSpacing: CGFloat, scale: CGFloat) -> CGFloat {
        let factor = max(1, captionLineSpacing / referenceCaptionLineSpacing)
        let s = scale > 0 ? scale : 1
        return (base * factor * s).rounded() / s
    }

    /// Logged `transcriptBoldTextAlignmentInsets` by caption point size.
    private static let captionInsets: [(size: CGFloat, top: CGFloat, bottom: CGFloat)] = [
        (11, 7.0 / 3, 3), (13, 3, 3), (15, 11.0 / 3, 10.0 / 3), (17, 13.0 / 3, 4), (20, 14.0 / 3, 5),
        (24, 6, 17.0 / 3), (29, 7, 20.0 / 3), (34, 25.0 / 3, 8), (40, 29.0 / 3, 10),
    ]

    /// `CKUIBehavior.transcriptBoldTextAlignmentInsets` (top, bottom) for the
    /// caption 2 point size (iOS 26.5 and 27.0): how far a timestamp's line
    /// box reaches beyond its type. Sizes between the logged ones interpolate.
    public static func captionAlignmentInsets(pointSize: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let table = captionInsets
        if pointSize <= table[0].size {
            return (table[0].top * pointSize / table[0].size, table[0].bottom * pointSize / table[0].size)
        }
        for (low, high) in zip(table, table.dropFirst()) where pointSize <= high.size {
            let t = (pointSize - low.size) / (high.size - low.size)
            return (low.top + (high.top - low.top) * t, low.bottom + (high.bottom - low.bottom) * t)
        }
        let last = table[table.count - 1]
        return (last.top * pointSize / last.size, last.bottom * pointSize / last.size)
    }

    /// Bubble body bottom to the timestamp's line box: ChatKit puts the type
    /// `mediumLargeSpace` under the body.
    public static func timestampLineGap(captionLineSpacing: CGFloat, captionPointSize: CGFloat, scale: CGFloat) -> CGFloat {
        space(mediumLargeSpace, captionLineSpacing: captionLineSpacing, scale: scale)
            - captionAlignmentInsets(pointSize: captionPointSize).top
    }

    /// The timestamp's line box to the next bubble body: `mediumSpace` from
    /// the type.
    public static func timestampFollowingGap(captionLineSpacing: CGFloat, captionPointSize: CGFloat, scale: CGFloat) -> CGFloat {
        space(mediumSpace, captionLineSpacing: captionLineSpacing, scale: scale)
            - captionAlignmentInsets(pointSize: captionPointSize).bottom
    }

    /// `largeTranscriptSpace` at Large.
    public static let largeSpace: CGFloat = 20

    /// The service header ("iMessage / Encrypted") to the first timestamp's
    /// line box: `largeSpace` between the two lines of type.
    public static func headerToTimestampGap(captionLineSpacing: CGFloat, captionPointSize: CGFloat, scale: CGFloat) -> CGFloat {
        let insets = captionAlignmentInsets(pointSize: captionPointSize)
        return space(largeSpace, captionLineSpacing: captionLineSpacing, scale: scale) - insets.top - insets.bottom
    }
}
