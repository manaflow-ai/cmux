import CoreGraphics

/// The frame-shift measure's account between two samples (``PagedListProbe/frameShift``): how far
/// the offset moved for reasons the reader sees as scrolling (explained), and the corrections UIKit
/// still owes for rows above the reader that changed height (pending), so the offset move that pays
/// one is not taken for the person's scroll. Plain values, so the rules are tested without UIKit.
struct PagedListShiftLedger {
    /// Offset moves since the last sample that the scroll explains.
    private(set) var explained: CGFloat = 0
    /// The same since the last committed frame (the committed-frame measure's interval).
    private(set) var committedExplained: CGFloat = 0
    /// Corrections the layout or UIKit asked for and has yet to apply.
    private(set) var pending: CGFloat = 0
    /// The corrections owed for rows that sized above the reader, by row: the layout may ask for
    /// the same one again (`corrected`), which is owed once.
    private var owed: [Int: CGFloat] = [:]
    /// The corrections paid since the last layout pass: the offset moved, the visible cells move
    /// in the next pass. Not an interval's: a sample does not clear it.
    private var unlaid: CGFloat = 0

    /// An offset move the scroll explains: the finger, a fling, the list's own deliberate move.
    mutating func explain(_ delta: CGFloat) {
        explained += delta
        committedExplained += delta
    }

    /// A committed frame was sampled: its interval starts empty.
    mutating func resetCommitted() {
        committedExplained = 0
    }

    /// What a frame drew of the row being read, from how far each of its edges moved on screen
    /// (each with what the scroll explains already taken out). A row that changes height in place
    /// moves one edge and keeps the other, and which one depends on whether the layout corrects the
    /// offset for it: the up-*-flood rows grew at their top under the bars (bottom kept, steps
    /// 6d8bcee4 and f902d4d6), the down-*-edits rows shrank at their bottom (top kept, step
    /// d20b5519). Nothing the reader sees moved in either. A drawn shift moves the whole row, both
    /// edges the same way; the part both edges share is the shift.
    static func drawnShift(top: CGFloat, bottom: CGFloat) -> CGFloat {
        guard top * bottom > 0 else { return 0 }
        return abs(top) < abs(bottom) ? top : bottom
    }

    /// The layout asked to move the offset by `delta` to keep the rows below a row that changed
    /// height (`item`) where they were.
    mutating func corrected(_ delta: CGFloat, item: Int?) {
        if let item, let sized = owed.removeValue(forKey: item) {
            pending += delta - sized
        } else {
            pending += delta
        }
    }

    /// A row's cell sized itself `delta` taller (or shorter) than the layout had it; `aboveReader`
    /// when the row starts above the reader's top edge. Such a row moves everything the reader sees,
    /// and the offset follows it to keep them in place: UIKit does that itself for a cell it sizes
    /// outside a layout pass (one it prepares ahead of the scroll), with no layout correction to
    /// announce it, from a set of the offset that looks like the scroll's own.
    mutating func sized(item: Int, by delta: CGFloat, aboveReader: Bool) {
        guard aboveReader else { return }
        owed[item, default: 0] += delta
        pending += delta
    }

    /// Whether an offset move of `delta` pays a pending correction (UIKit may pay several rows'
    /// corrections one at a time or together); takes it from what is pending when it does.
    mutating func pays(_ delta: CGFloat) -> Bool {
        guard pending != 0, delta * pending > 0, abs(delta) <= abs(pending) + 0.5 else { return false }
        pending = abs(pending - delta) < 0.5 ? 0 : pending - delta
        unlaid += delta
        return true
    }

    /// The offset the visible cells were last laid out against, from the offset now: a layout pass
    /// that keeps the reader in place holds them against it. Each pass takes it once.
    mutating func takeDrawnOffset(_ offset: CGFloat) -> CGFloat {
        defer { unlaid = 0 }
        return offset - unlaid
    }

    /// A sample was taken: the next interval starts empty.
    mutating func reset() {
        explained = 0
        pending = 0
        owed.removeAll(keepingCapacity: true)
    }
}
