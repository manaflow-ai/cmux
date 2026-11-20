import CoreGraphics

/// The frame-shift measure's account between two samples (``PagedListProbe/frameShift``): how far
/// the offset moved for reasons the reader sees as scrolling (explained), and the corrections UIKit
/// still owes for rows above the reader that changed height (pending), so the offset move that pays
/// one is not taken for the person's scroll. Plain values, so the rules are tested without UIKit.
struct PagedListShiftLedger {
    /// Offset moves since the last sample that the scroll explains.
    private(set) var explained: CGFloat = 0
    /// Corrections the layout or UIKit asked for and has yet to apply.
    private(set) var pending: CGFloat = 0

    /// An offset move the scroll explains: the finger, a fling, the list's own deliberate move.
    mutating func explain(_ delta: CGFloat) {
        explained += delta
    }

    /// The layout asked to move the offset by `delta` to keep the rows below a row that changed
    /// height (`item`) where they were.
    mutating func corrected(_ delta: CGFloat, item: Int?) {
        pending += delta
    }

    /// A row's cell sized itself `delta` taller (or shorter) than the layout had it; `aboveReader`
    /// when the row starts above the reader's top edge. The measure ignores it.
    mutating func sized(item: Int, by delta: CGFloat, aboveReader: Bool) {}

    /// Whether an offset move of `delta` pays a pending correction (UIKit may pay several rows'
    /// corrections one at a time or together); takes it from what is pending when it does.
    mutating func pays(_ delta: CGFloat) -> Bool {
        guard pending != 0, delta * pending > 0, abs(delta) <= abs(pending) + 0.5 else { return false }
        pending = abs(pending - delta) < 0.5 ? 0 : pending - delta
        return true
    }

    /// A sample was taken: the next interval starts empty.
    mutating func reset() {
        explained = 0
        pending = 0
    }
}
