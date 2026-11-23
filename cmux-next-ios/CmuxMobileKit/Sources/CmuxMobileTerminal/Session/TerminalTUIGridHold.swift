import Foundation

/// The rows a full-screen app's area shows while the Mac redraws it at the
/// page's new rows (design/terminal M-BLACK).
///
/// The soft keyboard never changes the rows (`TerminalGridSizing`), but a
/// chrome change does (Hide Toolbar, a tab's insets, the composer's resting
/// height). The grid on screen is still the Mac's old one until the resize's
/// mirror reset and replay are in (a settle and a round trip later). Sized to
/// the new rows at once, the area showed the old grid off the composer, or
/// over a band of black with the letterbox note ("53×25 · set by another
/// device") in it, and then the replay moved it again.
///
/// So while that answer is on its way, the area keeps the old grid's rows,
/// pinned to the composer; the replay's frame swaps in the new grid in one
/// step (behind the held frame).
public struct TerminalTUIGridHold: Equatable, Sendable {
    /// The rows of the grid on screen, kept while the Mac's new grid is on
    /// its way (nil: the area shows the page's rows).
    public private(set) var heldRows: Int?

    /// The longest the old grid is kept: the resize's settle and a claim's
    /// round trip (`TerminalReclaimHold.reclaimWait`). Past it, no answer is
    /// coming (the Mac kept its grid) and the area shows the page's rows.
    public static let cap: Duration = TerminalResizeSettle.settle + TerminalReclaimHold.reclaimWait
    /// `cap` in seconds.
    public static var capSeconds: Double {
        Double(cap.components.seconds) + Double(cap.components.attoseconds) / 1e18
    }

    public init() {}

    /// The page's rows changed from `old` to `new` while the screen shows the
    /// Mac's grid of `shownRows` rows (nil: a local session, whose grid
    /// follows a resize at once).
    public mutating func rowsChanged(from old: Int, to new: Int, shownRows: Int?) {
        guard let shownRows, shownRows != new else {
            heldRows = nil
            return
        }
        // Held already (the rows changed back before the Mac answered):
        // the grid on screen is still the one held.
        if heldRows != nil { return }
        // Only the phone's own grid is held: a grid another device set is
        // shown letterboxed or shifted as it is (TerminalHostGridLayout).
        heldRows = shownRows == old ? shownRows : nil
    }

    /// A replay at the Mac's grid of `rows` rows is parsed; the page has
    /// `page` rows, and `claimPending` says a resize to them is still to be
    /// answered (unsent, or sent after the size this replay answers). The
    /// grid on screen is now the replay's: the area shows the page's rows,
    /// or, while the page's own answer is still coming, the replay's grid
    /// (a second change before the first answer: 40, then 25 asked, then 30).
    public mutating func replayed(rows: Int?, page: Int, claimPending: Bool) {
        guard let rows, rows != page, claimPending else {
            heldRows = nil
            return
        }
        heldRows = rows
    }

    /// The app left the alternate screen, or no answer came: the area shows
    /// the page's rows.
    public mutating func release() {
        heldRows = nil
    }

    /// The rows the area shows for the page's `rows`.
    public func rows(page rows: Int) -> Int { heldRows ?? rows }
}

