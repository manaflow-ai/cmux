import CoreGraphics
import Foundation

/// The page must never show the terminal's background where rows belong
/// (VERIFY-round6 V6-2, V6-3, V6-4: black for 1-60 s after a prune while
/// following, a Jump to bottom, two quick drops, until the next touch).
///
/// Every display frame the screen says whether the frame on screen (the
/// surface's `surfaceRows` rows from `presentedTop`) covers the rows the
/// page shows. Something that waits for a frame (a jump, a follow, a held
/// replay) may leave them uncovered for a moment; past `deadline` the watch
/// asks for a recovery (place the frame by Ghostty's report and ask for a
/// new one), and asks again every `deadline` until covered. It also counts
/// the uncovered stretches for the frame log (G-04).
public struct TerminalBlankWatch: Equatable, Sendable {
    /// How long rows may stay uncovered before a recovery.
    public static let deadline: TimeInterval = 0.25

    public private(set) var uncoveredSince: TimeInterval?
    private var lastRecovery: TimeInterval?
    /// Uncovered stretches that reached the deadline, and the longest one.
    public private(set) var events = 0
    public private(set) var longest: TimeInterval = 0

    public init() {}

    /// Whether the frame at `presentedTop` (`surfaceRows` rows) covers the
    /// visible rows `visibleTop..<visibleBottom`, clipped to the document's
    /// rows `documentRows` (rows outside it are the page's own blank).
    public static func covers(presentedTop: Int, surfaceRows: Int, visibleTop: Int, visibleBottom: Int,
                              documentRows: Range<Int>) -> Bool {
        let top = max(visibleTop, documentRows.lowerBound)
        let bottom = min(visibleBottom, documentRows.upperBound)
        guard bottom > top else { return true }
        return top >= presentedTop && bottom <= presentedTop + surfaceRows
    }

    /// Points of the legible band (`legible`, content y: below the top
    /// inset, above the composer) inside the document (`document`) that the
    /// frame on screen (`frame`, the surface's span) does not cover.
    public static func uncoveredHeight(frame: Range<CGFloat>, document: Range<CGFloat>, legible: Range<CGFloat>) -> CGFloat {
        let lower = max(document.lowerBound, legible.lowerBound)
        let upper = min(document.upperBound, legible.upperBound)
        guard upper > lower else { return 0 }
        let coveredLower = max(lower, frame.lowerBound)
        let coveredUpper = min(upper, frame.upperBound)
        return (upper - lower) - max(0, coveredUpper - coveredLower)
    }

    /// The frame log's `blank` (VERIFY-round8): a person sees the page's
    /// background where rows belong, at least a row's height of it (a sliver
    /// at an edge, rows under the composer or the keyboard are not seen).
    public static func showsBlank(frame: Range<CGFloat>, document: Range<CGFloat>, legible: Range<CGFloat>,
                                  cellHeight: CGFloat) -> Bool {
        uncoveredHeight(frame: frame, document: document, legible: legible) >= max(1, cellHeight)
    }

    /// One display frame. True: recover now.
    public mutating func observe(covered: Bool, now: TimeInterval) -> Bool {
        guard !covered else {
            if let since = uncoveredSince { longest = max(longest, now - since) }
            uncoveredSince = nil
            lastRecovery = nil
            return false
        }
        guard let since = uncoveredSince else {
            uncoveredSince = now
            return false
        }
        guard now - since >= Self.deadline else { return false }
        if lastRecovery == nil { events += 1 }
        longest = max(longest, now - since)
        if let last = lastRecovery, now - last < Self.deadline { return false }
        lastRecovery = now
        return true
    }
}
