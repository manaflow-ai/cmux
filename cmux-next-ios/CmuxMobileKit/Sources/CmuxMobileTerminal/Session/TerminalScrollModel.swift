import CoreGraphics

/// The one owner of the terminal's scroll position (verify/terminal-scroll-model.md).
///
/// Three states:
/// - `following`: pinned to the bottom; new output keeps it there.
/// - `reading(anchor)`: the person scrolled away; the position is a content
///   row's identity (its absolute row in Ghostty's scrollback plus a pixel
///   remainder), so output, a redraw below, or a document that grows or moves
///   its top never moves the rows being read.
/// - `interacting`: a finger is down or the page decelerates; nothing but
///   UIKit moves it.
///
/// Transitions happen only on the person's input (drag start, release or the
/// end of a deceleration, typing, Jump to bottom) or a real reset (a
/// reattach or a resize replaying the mirror). The controller asks
/// `target(...)` once per display frame, after layout, and sets the offset
/// only when it differs; no other code sets it.
public struct TerminalScrollModel: Equatable, Sendable {
    public struct Anchor: Equatable, Sendable {
        /// The absolute row at the top edge of the scroll view's bounds.
        public var row: Int
        /// The offset's remainder below that row's top (points).
        public var delta: CGFloat
    }

    public enum State: Equatable, Sendable {
        case following
        case reading(Anchor)
        case interacting(startedFollowing: Bool)
    }

    /// Within this many rows of the bottom, a release or a deceleration's
    /// end follows again.
    public static let followSlackRows: CGFloat = 2

    public private(set) var state: State = .following
    /// The gesture reached the bottom edge (a fling into the bottom while
    /// output streams ends a few rows short of the newest end).
    private var touchedBottom = false
    /// Rows of slack after the gesture touched the bottom.
    public static let touchedBottomSlackRows: CGFloat = 8
    /// The gesture's last move above the bottom edge was toward older rows
    /// (V5-2: a fling up from the live bottom is not a fling into it).
    private var movedUp = false
    private var lastOffsetY: CGFloat?
    /// A restore set `.reading` and the page has not reached its rows yet
    /// (the controller waits for their frame; ``reachedTarget()``).
    private var unplaced = false
    /// The reader's rows a restore handed to a gesture holding the page
    /// (``restoreReading(_:)``), while nothing has moved the page since:
    /// the gesture's settle reads them, not the offset.
    private var restoredUnderGesture: Anchor?

    public init() {}

    public var isFollowing: Bool { state == .following }
    public var isInteracting: Bool { if case .interacting = state { true } else { false } }

    // MARK: Input

    /// A finger came down on the page (a drag begins). Returns the reader's
    /// restored rows when the page has not reached them yet
    /// (``reachedTarget()``): the controller puts the page there first.
    @discardableResult
    public mutating func began() -> Anchor? {
        touchedBottom = false
        movedUp = false
        lastOffsetY = nil
        var restored: Anchor?
        if unplaced, case .reading(let anchor) = state { restored = anchor }
        unplaced = false
        restoredUnderGesture = nil
        state = .interacting(startedFollowing: isFollowing || (isInteracting && startedFollowing))
        return restored
    }

    /// A restore set `.reading` and the page has not reached its rows yet.
    public var awaitsPlacement: Bool { unplaced }

    /// The page's offset is the target now (the controller set it).
    public mutating func reachedTarget() { unplaced = false }

    private var startedFollowing: Bool {
        if case .interacting(let following) = state { following } else { false }
    }

    /// The page moved under a finger or a deceleration.
    public mutating func scrolled(offsetY: CGFloat, bottomOffsetY: CGFloat) {
        guard isInteracting else { return }
        // The direction counts above the bottom edge only: a bounce back
        // from past the end is not a move up.
        if let last = lastOffsetY, offsetY < bottomOffsetY - 0.5 {
            if offsetY < last - 0.5 { movedUp = true } else if offsetY > last + 0.5 { movedUp = false }
        }
        lastOffsetY = offsetY
        if offsetY >= bottomOffsetY - 0.5 { touchedBottom = true }
        // The finger moved the page off the restored rows: it reads where it leaves it.
        restoredUnderGesture = nil
    }

    /// The finger lifted with no deceleration, or a deceleration ended: rest
    /// here. Within `followSlackRows` of the bottom, follow.
    /// Only a gesture settles: after Jump to bottom (or typing) mid-gesture,
    /// the end of the deceleration or the lift it interrupted changes nothing.
    public mutating func settled(offsetY: CGFloat, bottomOffsetY: CGFloat, layout: TerminalDocumentLayout?, rowHeight: CGFloat) {
        guard isInteracting else { return }
        if let restored = restoredUnderGesture {
            // A restore found the reader's rows while this gesture held the
            // page, and nothing moved it since (the controller stopped a
            // fling there): rest on those rows. Until the page reaches them
            // (it may wait for their frame, showing another), a drag gets
            // them first (`began`). Steps 23a5dd6f9a59bd5ae686f20a and
            // 29d221e0ad16937d43b3e557: settled as plain reading, the next
            // drag began on the Mac's screen.
            restoredUnderGesture = nil
            touchedBottom = false
            movedUp = false
            lastOffsetY = nil
            state = .reading(restored)
            unplaced = true
            return
        }
        guard let layout, rowHeight > 0 else { state = .following; return }
        let slack = (touchedBottom && !movedUp ? Self.touchedBottomSlackRows : Self.followSlackRows) * rowHeight
        touchedBottom = false
        movedUp = false
        lastOffsetY = nil
        if offsetY >= bottomOffsetY - slack {
            state = .following
        } else {
            state = .reading(Self.anchor(offsetY: offsetY, layout: layout, rowHeight: rowHeight))
        }
    }

    /// Typing, a paste, the key bar: back to the prompt, like Terminal.
    public mutating func input() {
        state = .following
        restoredUnderGesture = nil
    }

    /// Jump to bottom.
    public mutating func jumpToBottom() {
        state = .following
        restoredUnderGesture = nil
    }

    /// A fling moving toward newer rows reached the bottom: it follows from
    /// here, while UIKit finishes the deceleration and its rubber band past
    /// the end (the controller leaves a decelerating page alone). The end of
    /// the deceleration changes nothing more (`settled` needs a gesture).
    public mutating func flingReachedBottom() {
        guard isInteracting else { return }
        state = .following
        restoredUnderGesture = nil
    }

    /// The mirror was reset and replayed (reattach, resize) or the scrollback
    /// was cleared: the rows being read are gone.
    public mutating func reset() {
        state = .following
        unplaced = false
        restoredUnderGesture = nil
    }

    /// A mirror reset's replay is in: the reader goes back to their rows
    /// (TerminalReadingMark), whatever a gesture did since the reset. That
    /// gesture moved a page of the old replay's rows (the reset follows the
    /// old document's bottom), so its anchor names other rows in the new
    /// replay: past a history window's end, the Mac's screen (#43189, step
    /// 86896cb9e08d3fe4de04a693). Returns the anchor the controller puts the
    /// page on itself while a gesture still holds it (the state stays the
    /// gesture's until it settles); nil when the state places it.
    @discardableResult
    public mutating func restoreReading(_ anchor: Anchor) -> Anchor? {
        if isInteracting {
            restoredUnderGesture = anchor
            return anchor
        }
        state = .reading(anchor)
        unplaced = true
        return nil
    }

    /// Find revealed a match: the page reads from `row` plus `delta` points (its top
    /// edge; a negative delta starts above the row, under the top bar's inset), unless a
    /// finger owns the page. Output then never moves the match away.
    public mutating func reveal(row: Int, delta: CGFloat = 0) {
        guard !isInteracting else { return }
        touchedBottom = false
        movedUp = false
        lastOffsetY = nil
        state = .reading(Anchor(row: max(0, row), delta: delta))
    }

    /// Ghostty pruned `-rows` of its oldest rows (`TerminalHistoryPrune`):
    /// the rows being read keep their identity under the new numbering.
    public mutating func shiftRows(by rows: Int) {
        restoredUnderGesture = restoredUnderGesture.map { Anchor(row: max(0, $0.row + rows), delta: $0.delta) }
        guard case .reading(var anchor) = state else { return }
        anchor.row = max(0, anchor.row + rows)
        state = .reading(anchor)
    }

    /// The keyboard follows the finger in a drag that began at the prompt
    /// (M6): the prompt rides the composer for the rest of the gesture.
    public mutating func keyboardDragPinned() { state = .interacting(startedFollowing: true) }

    // MARK: Output

    /// The offset to show now, or nil to leave it alone (a finger or a
    /// deceleration owns it).
    public func target(layout: TerminalDocumentLayout?, rowHeight: CGFloat, topInset: CGFloat,
                       bottomOffsetY: CGFloat) -> CGFloat? {
        switch state {
        case .following:
            return bottomOffsetY
        case .interacting:
            return nil
        case .reading(let anchor):
            guard let layout, rowHeight > 0 else { return nil }
            let y = layout.contentY(ofRow: anchor.row, cellHeight: rowHeight) + anchor.delta
            return min(max(-topInset, y), bottomOffsetY)
        }
    }

    static func anchor(offsetY: CGFloat, layout: TerminalDocumentLayout, rowHeight: CGFloat) -> Anchor {
        let row = layout.row(atContentY: offsetY, cellHeight: rowHeight)
        return Anchor(row: row, delta: offsetY - layout.contentY(ofRow: row, cellHeight: rowHeight))
    }
}
