import AppKit

/// cmux: what in an open thread view a click acts on, for its outside-click close (`PaneThread.clicked`).
/// Lawrence 2026-11-07: "clicking some parts of empty space still doesn't get out of this view". The thread's
/// rows span the view's width, so a click beside a bubble, or on a date or "Read" line, landed inside a row and
/// kept the view open. Only the bubbles (with their links and tapbacks), the drawn controls of the rows that are
/// controls ("N Replies", a thread preview, an unsent note, an "Edited" or failed label) and the thread's header
/// count; the rest is empty space.
/// Lawrence 2026-11-18: "clicking some space fails to close it": the control rows still counted across the whole
/// width (a nested reply's "1 Reply" line took any click at its height), so only their drawn words count now.
extension MessagesWindowView {
    func threadContentHit(_ p: CGPoint) -> Bool {
        guard threadContentContains(p) else { return false }
        let rows = zip(threadViews, threadSpecs).filter { $0.0.frame.insetBy(dx: 0, dy: RowDraw.margin).contains(p) }
        // Inside the thread's content but in no row: the thread's header.
        if rows.isEmpty { return true }
        if hit(p) != nil { return true }
        return rows.contains { v, spec in Self.threadRowControl(spec, frame: v.frame)?.contains(p) == true }
    }

    /// The part of a thread view row that is a control, in this view's coordinates (`frame` is the row's, with its
    /// ``RowDraw/margin`` above and below): the drawn words of "N Replies", an unsent note or a non-secondary label,
    /// padded to a comfortable target, or a thread preview's quote and its "N Replies". nil for a row that is no
    /// control (a bubble row, whose bubble ``hit(_:)`` answers; a date, "Read" or sender line).
    static func threadRowControl(_ spec: RowSpec, frame: CGRect) -> CGRect? {
        let m = spec.metrics
        let band = CGRect(x: frame.minX, y: frame.minY + RowDraw.margin, width: frame.width, height: spec.height)
        // A word's ink as RowDraw.drawStatic places it, 8 pt wider each side and 4 pt taller (the desktop's
        // smallest target for a 10 pt line is about 18 pt).
        func words(x: CGFloat, width: CGFloat) -> CGRect {
            CGRect(x: frame.minX + x - 8, y: band.minY - 4, width: width + 16, height: band.height + 8)
        }
        switch spec.kind {
        case let .replies(count, _, outgoing):
            let w = TextDraw.width(Strings.replies(count), font: HomeFonts.system(ofSize: 10, weight: .semibold), kern: RowDraw.captionKern)
            return words(x: outgoing ? m.receiptRight - w : Fixture.labelLeft + spec.cmuxIndent, width: w)
        case let .label(text, outgoing, color):
            guard color != .secondary else { return nil }
            let w = TextDraw.width(text, font: HomeFonts.system(ofSize: 10, weight: .medium))
            return words(x: outgoing ? m.receiptRight - w : Fixture.labelLeft + spec.cmuxIndent, width: w)
        case let .unsent(outgoing):
            let w = TextDraw.width(outgoing ? Strings.unsentMine : Strings.unsentTheirs, font: HomeFonts.system(ofSize: 11))
            return words(x: m.centerX - w / 2, width: w)
        case let .threadPreview(pv):
            // As `repliesHit` reads a preview in the transcript: its quote, at least 90 pt wide, from its side.
            let span = max(pv.box.width, 90)
            let x = pv.outgoing ? m.rightEdge - span : pv.cmuxLeft
            return CGRect(x: frame.minX + x, y: band.minY, width: span, height: band.height)
        default:
            return nil
        }
    }
}
