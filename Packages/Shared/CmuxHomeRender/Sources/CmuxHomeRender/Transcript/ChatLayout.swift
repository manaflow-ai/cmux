import CoreGraphics

/// Bottom-anchored layout. Rows sit at `rowsBottom - total`, where
/// `rowsBottom = contentHeight - bottomPad`. Appending rows does not change
/// the content height, so existing rows move up (animated by the change) and
/// a transcript pinned to the bottom keeps its scroll offset. The slack above
/// the oldest row is rebased when it leaves its range (the offset and the
/// height move together, so nothing moves on screen).
@MainActor
final class ChatLayout {
    let model: TranscriptModel
    var width: CGFloat = Style.referenceWidth
    private(set) var contentHeight: CGFloat = 0
    /// Space below the last row (viewport height minus the transcript anchor).
    var bottomPad: CGFloat = 0
    static let slackTarget: CGFloat = 6000
    static let slackRange: ClosedRange<CGFloat> = 2500...20000

    init(model: TranscriptModel) { self.model = model }

    var rowsBottom: CGFloat { contentHeight - bottomPad }
    var rowsTop: CGFloat { rowsBottom - model.total }

    func contentTop(_ i: Int) -> CGFloat { rowsTop + model.contentTop(i) }

    /// Row i's layer frame (content coordinates), with the drawing margin.
    func frame(for i: Int) -> CGRect {
        let h = model.rows[i].spec.height
        return CGRect(x: 0, y: contentTop(i) - Style.rowMargin, width: width, height: h + 2 * Style.rowMargin)
    }

    /// Rebases when the slack left its range (or always with `force`).
    /// Returns the content offset change.
    func rebaseIfNeeded(force: Bool = false) -> CGFloat {
        guard force || !Self.slackRange.contains(rowsTop) || contentHeight == 0 else { return 0 }
        let new = Self.slackTarget + model.total + bottomPad
        let d = new - contentHeight
        contentHeight = new
        return d
    }

    /// Rows whose frame intersects `rect` (content coordinates).
    func rows(in rect: CGRect) -> [Int] {
        model.range(rect.minY - rowsTop - 40, rect.maxY - rowsTop + 40).filter { frame(for: $0).intersects(rect) }
    }
}
