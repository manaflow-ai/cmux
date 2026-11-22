import CoreGraphics

/// How tall a growing composer field is for its text (every composer: the
/// terminal's message composer and the agent chat's).
///
/// The field grows upward with its draft, one line at a time, up to
/// `maxLines`; past that it keeps that height and scrolls inside. Its height
/// depends only on the measured text height, so a keystroke that does not
/// change the line count never changes the height (user report 2026-11-12:
/// the draft ran below the rounded field and "it go down when i y").
public struct ComposerFieldHeight: Equatable, Sendable {
    /// The most lines a composer shows before it scrolls (about a third of an
    /// iPhone's height above the keyboard).
    public static let defaultMaxLines = 6

    public let lineHeight: CGFloat
    /// The text container's top plus bottom inset.
    public let verticalInset: CGFloat
    public let maxLines: Int

    public init(lineHeight: CGFloat, verticalInset: CGFloat, maxLines: Int = Self.defaultMaxLines) {
        self.lineHeight = max(lineHeight, 1)
        self.verticalInset = max(verticalInset, 0)
        self.maxLines = max(maxLines, 1)
    }

    /// One line: the empty field's height.
    public var minHeight: CGFloat { (lineHeight + verticalInset).rounded(.up) }

    /// `maxLines` lines: the tallest the field gets.
    public var maxHeight: CGFloat { (lineHeight * CGFloat(maxLines) + verticalInset).rounded(.up) }

    /// The lines a measured text height holds (at least one).
    public func lines(contentHeight: CGFloat) -> Int {
        max(1, Int(((contentHeight - verticalInset) / lineHeight).rounded()))
    }

    /// Whether the text is taller than the field: it scrolls inside.
    public func scrolls(contentHeight: CGFloat) -> Bool {
        lines(contentHeight: contentHeight) > maxLines
    }

    /// The field's height for a measured text height: the text's own height
    /// (rounded up to whole points, never under one line) until it holds more
    /// than `maxLines` lines, then `maxHeight`.
    public func height(contentHeight: CGFloat) -> CGFloat {
        if scrolls(contentHeight: contentHeight) { return maxHeight }
        return min(max(contentHeight.rounded(.up), minHeight), maxHeight)
    }
}
