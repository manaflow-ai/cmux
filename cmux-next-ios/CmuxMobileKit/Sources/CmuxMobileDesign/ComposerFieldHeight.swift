import CoreGraphics
import Foundation

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

    /// The fewest lines a field keeps when something above it in the card (the attachment
    /// strip) takes part of its height.
    public static let minSharedLines = 2

    /// The lines a field may grow to when `reserved` points of the card above it are taken
    /// (the attachment strip, ``ComposerCardMetrics/attachmentStripHeight``): the strip's height
    /// comes out of the field's, so a card at its tallest stays that tall when a file is attached
    /// and the draft scrolls instead (Leo, 2026-11-23: "adding attachments shouldn then expand
    /// the fucking composer EVEN TALLER... this goes for the gui chat too... simply have it
    /// within the top part of the composer. the inner area grows at the top. no shift,
    /// nothing."). At least ``minSharedLines`` (or `maxLines`, if that is fewer).
    public static func maxLines(_ maxLines: Int, sharing reserved: CGFloat, lineHeight: CGFloat) -> Int {
        let maxLines = max(maxLines, 1)
        guard reserved > 0, lineHeight > 0 else { return maxLines }
        let taken = Int((reserved / lineHeight).rounded())
        return max(min(maxLines, minSharedLines), maxLines - taken)
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

    /// The field's height with an attachment strip `reserve` points tall
    /// inside the same composer: strip and text share the cap (Leo,
    /// 2026-11-23: "adding attachments shouldn then expand the [...] composer
    /// EVEN TALLER"), so the text gives up what the strip takes, down to one
    /// line, and scrolls inside.
    public func height(contentHeight: CGFloat, reserve: CGFloat) -> CGFloat {
        min(height(contentHeight: contentHeight), max(minHeight, maxHeight - max(reserve, 0)))
    }

    /// How far a `reserve`-point strip reaches above the field's height
    /// without it. The page's content inset leaves this out, so adding or
    /// removing attachments moves no transcript or terminal row ("the inner
    /// area grows at the top. no shift, nothing."): the strip draws over the
    /// rows behind it instead of pushing them.
    public func stripOverlap(contentHeight: CGFloat, reserve: CGFloat) -> CGFloat {
        guard reserve > 0 else { return 0 }
        let given = height(contentHeight: contentHeight) - height(contentHeight: contentHeight, reserve: reserve)
        return max(0, reserve - given)
    }
}

/// The tallest a composer gets, in lines of its text: past it the draft
/// scrolls inside, as ChatGPT's iOS composer does (Leo, 2026-11-23: "composer
/// growth in terminal view on ios is most certainly too high"; the terminal
/// had classic cmux's 14 lines).
public enum ComposerHeightCap {
    /// The chosen cap (`ComposerHeightCapUITests` gallery: 4, 6 and 8 lines).
    public static let defaultLines = ComposerFieldHeight.defaultMaxLines

    /// An attachment strip's height inside the composer: 56 pt tiles under
    /// a 12 pt top inset (the terminal's and the chat's strips).
    public static let stripHeight: CGFloat = 68

    /// The cap in force: `-cmux-mobile-composer-max-lines N` picks a gallery
    /// variant in DEBUG builds.
    public static var lines: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-cmux-mobile-composer-max-lines"), index + 1 < args.count,
           let lines = Int(args[index + 1]), lines > 0 {
            return lines
        }
        #endif
        return defaultLines
    }

    /// The terminal composer's cap: `lines`, or classic cmux's 14 under the
    /// DEBUG `-cmux-mobile-composer-legacy` (the before row of the proof).
    public static var terminalLines: Int { legacy ? 14 : lines }

    /// The room the field gives an attachment strip: the strip's height, or
    /// none under `-cmux-mobile-composer-legacy` (the strip stacked on top).
    public static func stripReserve(hasAttachments: Bool) -> CGFloat {
        hasAttachments && !legacy ? stripHeight : 0
    }

    /// DEBUG `-cmux-mobile-composer-legacy`: the composer as before the cap
    /// (14 terminal lines; a strip that adds its height and moves the rows),
    /// so one proof run measures before and after.
    public static var legacy: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-cmux-mobile-composer-legacy")
        #else
        return false
        #endif
    }
}
