import AppKit

/// cmux: what in an open thread view a click acts on, for its outside-click close (`PaneThread.clicked`).
/// Lawrence 2026-11-07: "clicking some parts of empty space still doesn't get out of this view". The thread's
/// rows span the view's width, so a click beside a bubble, or on a date or "Read" line, landed inside a row and
/// kept the view open. Only the bubbles (with their links and tapbacks), the rows that are controls ("N Replies",
/// a thread preview, an unsent or failed note) and the thread's header count; the rest is empty space.
extension MessagesWindowView {
    func threadContentHit(_ p: CGPoint) -> Bool {
        guard threadContentContains(p) else { return false }
        let rows = zip(threadViews, threadSpecs).filter { $0.0.frame.insetBy(dx: 0, dy: RowDraw.margin).contains(p) }
        // Inside the thread's content but in no row: the thread's header.
        if rows.isEmpty { return true }
        if hit(p) != nil { return true }
        return rows.contains { _, spec in
            switch spec.kind {
            case .replies, .threadPreview, .unsent: true
            case let .label(_, _, color): color != .secondary
            default: false
            }
        }
    }
}
