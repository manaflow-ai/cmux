import CoreGraphics

/// Layout of a Messages poll card, shared by the iOS and macOS surfaces.
/// Coordinates are top-left origin, relative to the card. Platform code
/// measures text and passes heights in; everything else is computed here.
///
/// Reference: iOS 26.3 MessagesPolls.bundle + ChatKit. Recovered exactly:
/// `pollsPluginMaxWidth` 368.4 (350 / 0.95), `pollsWinnerWidthPercentage`
/// 0.95, and the bar colors (see `PollCardColors`). The other metrics are
/// estimates (the bundle's StyleConstants values live in code, not data).
public enum PollCardGeometry {
    public struct Metrics: Sendable, Equatable {
        public var maxWidth: CGFloat
        public var padding: CGFloat
        public var titleToRows: CGFloat
        public var rowSpacing: CGFloat
        public var rowMinHeight: CGFloat
        public var rowCornerRadius: CGFloat
        public var rowVerticalPadding: CGFloat
        public var circleSize: CGFloat
        public var circleInset: CGFloat
        public var circleToText: CGFloat
        public var avatarSize: CGFloat
        /// Each avatar after the first overlaps the previous by this fraction.
        public var avatarOverlap: CGFloat
        public var maxAvatars: Int
        public var trailingInset: CGFloat
        public var avatarToText: CGFloat
        /// "Add Choice" stamp under the card.
        public var stampHeight: CGFloat

        public var textLeading: CGFloat { circleInset + circleSize + circleToText }

        /// iPhone, 17 pt text.
        public static let iOS = Metrics(
            maxWidth: 350 / 0.95, padding: 12, titleToRows: 10, rowSpacing: 6, rowMinHeight: 44,
            rowCornerRadius: 12, rowVerticalPadding: 11, circleSize: 24, circleInset: 10, circleToText: 10,
            avatarSize: 22, avatarOverlap: 0.35, maxAvatars: 3, trailingInset: 10, avatarToText: 8, stampHeight: 26
        )
        /// Mac, 13 pt text (scaled from iOS by the 13/17 body ratio).
        public static let macOS = Metrics(
            maxWidth: 300, padding: 9, titleToRows: 8, rowSpacing: 5, rowMinHeight: 32,
            rowCornerRadius: 9, rowVerticalPadding: 7, circleSize: 18, circleInset: 8, circleToText: 8,
            avatarSize: 17, avatarOverlap: 0.35, maxAvatars: 3, trailingInset: 8, avatarToText: 6, stampHeight: 20
        )
    }

    public struct Row: Equatable, Sendable {
        public var frame: CGRect
        public var circleFrame: CGRect
        public var textFrame: CGRect
        /// Trailing avatar stack area (empty when nobody voted).
        public var avatarsFrame: CGRect
        public var avatarFrames: [CGRect]
        /// The vote bar inside `frame` (zero width with no votes).
        public var barFrame: CGRect
    }

    public struct Layout: Equatable, Sendable {
        public var size: CGSize
        public var titleFrame: CGRect?
        public var rows: [Row]
    }

    /// Width of the avatar stack for `count` voters.
    public static func avatarsWidth(count: Int, _ m: Metrics) -> CGFloat {
        let shown = min(count, m.maxAvatars)
        guard shown > 0 else { return 0 }
        return m.avatarSize + CGFloat(shown - 1) * m.avatarSize * (1 - m.avatarOverlap)
    }

    /// Width available to a choice's text when `voterCount` people chose it.
    public static func textWidth(cardWidth: CGFloat, voterCount: Int, _ m: Metrics) -> CGFloat {
        let avatars = avatarsWidth(count: voterCount, m)
        let trailing = m.trailingInset + (avatars > 0 ? avatars + m.avatarToText : 0)
        return max(20, cardWidth - 2 * m.padding - m.textLeading - trailing)
    }

    /// Card width for a transcript column `available` points wide.
    public static func cardWidth(available: CGFloat, _ m: Metrics) -> CGFloat {
        min(m.maxWidth, available)
    }

    /// `titleHeight` nil omits the title. `rows` carries each choice's text
    /// height, voter count, and bar fraction (0...1 of the row width).
    public static func layout(
        width: CGFloat,
        titleHeight: CGFloat?,
        rows: [(textHeight: CGFloat, voterCount: Int, barFraction: CGFloat)],
        _ m: Metrics
    ) -> Layout {
        var y = m.padding
        var titleFrame: CGRect?
        if let titleHeight, titleHeight > 0 {
            titleFrame = CGRect(x: m.padding, y: y, width: width - 2 * m.padding, height: titleHeight)
            y += titleHeight + m.titleToRows
        }
        let rowWidth = width - 2 * m.padding
        var placed: [Row] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { y += m.rowSpacing }
            let height = max(m.rowMinHeight, row.textHeight + 2 * m.rowVerticalPadding)
            let frame = CGRect(x: m.padding, y: y, width: rowWidth, height: height)
            let circle = CGRect(x: frame.minX + m.circleInset, y: frame.midY - m.circleSize / 2, width: m.circleSize, height: m.circleSize)
            let stack = avatarsWidth(count: row.voterCount, m)
            let avatarsFrame = CGRect(
                x: frame.maxX - m.trailingInset - stack, y: frame.midY - m.avatarSize / 2,
                width: stack, height: stack > 0 ? m.avatarSize : 0
            )
            var avatarFrames: [CGRect] = []
            for i in 0..<min(row.voterCount, m.maxAvatars) {
                avatarFrames.append(CGRect(
                    x: avatarsFrame.minX + CGFloat(i) * m.avatarSize * (1 - m.avatarOverlap), y: avatarsFrame.minY,
                    width: m.avatarSize, height: m.avatarSize
                ))
            }
            let textWidth = textWidth(cardWidth: width, voterCount: row.voterCount, m)
            let text = CGRect(x: frame.minX + m.textLeading, y: frame.midY - row.textHeight / 2, width: textWidth, height: row.textHeight)
            let bar = CGRect(x: frame.minX, y: frame.minY, width: (rowWidth * max(0, min(1, row.barFraction))).rounded(), height: height)
            placed.append(Row(frame: frame, circleFrame: circle, textFrame: text, avatarsFrame: avatarsFrame, avatarFrames: avatarFrames, barFrame: bar))
            y += height
        }
        y += m.padding
        return Layout(size: CGSize(width: width, height: y.rounded(.up)), titleFrame: titleFrame, rows: placed)
    }
}

/// Poll colors from MessagesPolls.bundle Assets.car (sRGB, light / dark).
public enum PollCardColors {
    public typealias RGBA = (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    /// Bar for a choice I voted for (SelectedBarBackgroundColor).
    public static let selectedBar: (light: RGBA, dark: RGBA) = ((1, 0.741, 0.380, 1), (0.973, 0.686, 0.290, 1))
    /// Bar for a choice I did not vote for
    /// (DeselectedBarBackgroundColorRefreshEnabled).
    public static let deselectedBar: (light: RGBA, dark: RGBA) = ((1, 0.741, 0.380, 0.20), (1, 0.620, 0.110, 0.30))
    /// Row track under the bar (EditBackgroundColor; its use as the track is an estimate).
    public static let track: (light: RGBA, dark: RGBA) = ((0, 0, 0, 0.07), (1, 1, 1, 0.12))
    /// Empty vote circle stroke and accent text (EmptyCircleStrokeColor).
    public static let accent: RGBA = (1, 0.659, 0.2, 1)
    /// Checkmark on a selected circle (SelectedBarTextColorRefreshEnabled).
    public static let selectedGlyph: RGBA = (1, 1, 1, 1)
    /// Polls app icon tint (Orange).
    public static let icon: RGBA = (1, 0.729, 0.298, 1)
    public static let emptyCircleStrokeWidth: CGFloat = 1.5
}
