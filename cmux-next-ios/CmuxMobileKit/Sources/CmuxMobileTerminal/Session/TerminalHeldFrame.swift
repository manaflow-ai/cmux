import Foundation

/// When the frame held over a resize's mirror reset is let go (design/terminal
/// R3-2, R4): not before the new screen has a meaningful amount of content.
/// A TUI's replay at a new size can be an empty or near-empty alternate
/// screen until the program repaints (macOS `top` waits for its 1 s tick), and
/// releasing earlier showed a black band for a quarter of a second. Capped,
/// so a screen that stays empty is shown as it is.
public struct TerminalHeldFrame: Sendable {
    /// Share of the rows that must have text on the alternate screen.
    public static let minimumShare = 0.3
    /// The longest a frame is held.
    public static let cap: TimeInterval = 1.5

    public init() {}

    /// `nonBlankRows` of `rows` have text (`isAlternate`: a TUI's screen).
    public func shouldRelease(isAlternate: Bool, nonBlankRows: Int, rows: Int, elapsed: TimeInterval) -> Bool {
        if elapsed >= Self.cap { return true }
        guard isAlternate else { return nonBlankRows > 0 || rows == 0 }
        guard rows > 0 else { return true }
        return Double(nonBlankRows) >= max(1, Double(rows) * Self.minimumShare)
    }

    /// A present while a frame is held (qa11 wt-read2-a): let it go only
    /// once the replay drew (`replayDrawn`), a reader's rows are restored
    /// (`markPending` false) and the frame just placed (`cover`) covers the
    /// rows the page shows (`visibleTop..<visibleBottom` within
    /// `documentRows`). Released on the first present after the restore, the
    /// page showed Ghostty's frame of the end placed at the end while the
    /// page stood at the reader's rows: one black frame. A TUI's screen has
    /// no scroll: drawn is enough.
    static func releasesOnPresent(isAlternate: Bool, replayDrawn: Bool, markPending: Bool, cover: TerminalFrameCover,
                                  visibleTop: Int, visibleBottom: Int, documentRows: Range<Int>) -> Bool {
        guard replayDrawn, !markPending else { return false }
        if isAlternate { return true }
        return TerminalBlankWatch.covers(presentedTop: cover.presentedTop, surfaceRows: cover.surfaceRows, visibleTop: visibleTop,
                                         visibleBottom: visibleBottom, documentRows: documentRows)
    }

    /// The longest a frame is held while the frame placed does not cover the
    /// page's rows (termqa N1): past it the page shows what there is.
    public static let coverCap: TimeInterval = 5

    /// At `cap` after the reset (termqa N1): let the held frame go only when
    /// the frame placed covers the rows the page shows (a TUI's screen: at
    /// once), or `coverCap` has passed. Released at the cap regardless, a
    /// restore whose frame was not placed yet left the page black for
    /// 250 ms until the blank watch placed it.
    static func releasesAtCap(isAlternate: Bool, cover: TerminalFrameCover, visibleTop: Int, visibleBottom: Int,
                              documentRows: Range<Int>, elapsed: TimeInterval) -> Bool {
        if isAlternate || elapsed >= coverCap { return true }
        return TerminalBlankWatch.covers(presentedTop: cover.presentedTop, surfaceRows: cover.surfaceRows, visibleTop: visibleTop,
                                         visibleBottom: visibleBottom, documentRows: documentRows)
    }

    /// Rows with text in Ghostty's plain text of a screen (one line per row;
    /// soft-wrapped rows joined count once, which only errs toward holding).
    public static func nonBlankRows(in text: String, limit: Int) -> Int {
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit)
            where line.contains(where: { !$0.isWhitespace }) {
            count += 1
        }
        return count
    }
}
