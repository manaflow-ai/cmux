internal import CCmuxMotionFFI
public import CoreGraphics

/// Where a sidebar row's hover card sits, and which part of the screen keeps it
/// (`HoverCardPlacement.besideRow`). Pure: no window, no view. The rule is cmux-motion's
/// (`hover::HoverCardEscapeGeometry`, through `cmux_hover_escape_geometry`); this value keeps
/// its result.
///
/// Leo 2026-10-21: "WHY HAS IT NOT BEEN ALIGNED". The card sits beside the sidebar with its top
/// on the hovered row's top, as Chrome's and Arc's tab hover cards do, and it follows the row
/// from row to row. Near the screen's bottom edge the visible frame clamps it up (it still covers
/// the row's side); near its right edge it goes left of the row.
///
/// Leo 2026-10-28: "the gap between the hover preview and ... the workspace sidebar element".
/// Workspace cards anchor on the drawn row's fill, before the resize/drag thumb. Group headers
/// and rail marks retain their column band (`rowBand(row:column:)`). The card touches its anchor.
///
/// ```
///   +---- sidebar column ---------------------------+
///   |  +----------------+--------------------+      |
///   |  |      row       |        card        |      |   (the card's top on the row's top,
///   |  +----------------+                    |      |    touching the row's fill)
///   |                   +--------------------+      |
/// ```
///
/// The gap keeps the card only for a pointer heading into it (`HoverCardCoordinator`); one
/// moving down past the row lets it go (Leo 2026-10-20).
///
/// `RowAlignment.middle` keeps the earlier layout (#22473, Leo 2026-10-20 "trapped by the
/// preview"): the card's top on the row's middle, so right of the row's upper half is an empty
/// escape slot that dismisses the card. It flips above the row's middle near the screen's bottom.
/// Debug Settings turns it back on (`escapeSlotTunable`). Coordinates are screen points, y up.
public nonisolated struct HoverCardEscapeGeometry: Hashable, Sendable {
    /// What a point is, for a shown card.
    public enum Zone: Hashable, Sendable {
        /// On the row the card describes.
        case row
        /// On the card.
        case card
        /// In the empty slot beside the row: the card goes.
        case escape
        /// Between the row and the card: the card stays only for a pointer heading into it.
        case gap
        /// Anywhere else.
        case outside
    }

    /// The row's frame.
    public private(set) var anchor: CGRect
    /// The card's frame at rest.
    public private(set) var card: CGRect
    /// The empty slot beside the row that the card never covers; empty when the screen left
    /// no room for one.
    public private(set) var escapeSlot: CGRect
    /// The strip between the row and the card, beside the card; empty when they touch.
    public private(set) var gapStrip: CGRect
    /// The card sits left of its row (no room on the right).
    public private(set) var isLeading: Bool

    /// Which edge of the card goes where on its row.
    public enum RowAlignment: Hashable, Sendable {
        /// The card's top on the row's top (Chrome, Arc). No escape slot.
        case top
        /// The card's top on the row's middle, below an escape slot beside the row's upper half.
        case middle
    }

    /// The room between a target and a `.beside` card (the update card or a pull request badge's
    /// card): one device pixel of `scale`. Sidebar row cards use ``rowGap`` so they sit
    /// directly against the row and its resize/drag edge.
    public static func edgeGap(scale: CGFloat) -> CGFloat { cmux_hover_edge_gap(scale) }

    /// Sidebar row cards sit directly against their anchor. Keeping this separate from
    /// ``edgeGap(scale:)`` preserves the small breathing room used by non-sidebar `.beside` cards.
    public static let rowGap: CGFloat = 0

    /// A sidebar row's anchor for its card: the row's height across the whole sidebar column.
    ///
    /// The card's top lines up with `row`'s top and its near edge with the column's visible edge,
    /// so a row's inset, trailing trim or group depth never moves the card sideways.
    /// - Parameter row: The row's frame on screen (its pill, a header, a rail mark).
    /// - Parameter column: The sidebar column's visible frame on screen; only its x extent is used.
    /// - Returns: `row`'s vertical extent spanning `column`'s horizontal one.
    public static func rowBand(row: CGRect, column: CGRect) -> CGRect {
        cmux_hover_row_band(CmuxHoverRect(row), CmuxHoverRect(column)).cgRect
    }

    /// The room a row's card rests in: the screen's visible frame less `margin`, and between its
    /// window's bottom and top, so the last row's card never hangs below the window (Lawrence
    /// 2026-10-22). The window takes no margin. Across, the room is the screen's: the card goes
    /// beside the sidebar, past the window's edge when the window is no wider than the sidebar,
    /// and never over the rows it describes.
    /// - Parameter visible: The screen's visible frame (or the whole screen), screen coordinates.
    /// - Parameter window: The parent window's frame; nil out of a window.
    public static func room(visible: CGRect, window: CGRect?, margin: CGFloat) -> CGRect {
        cmux_hover_card_room(CmuxHoverRect(visible), window != nil, CmuxHoverRect(window ?? .zero), margin).cgRect
    }

    /// Debug Settings: the escape-slot layout (`RowAlignment.middle`) instead of the top-aligned one.
    public static let escapeSlotTunable = Tunable<Bool>.toggle(
        "sidebar.hoverCardEscapeSlot", .sidebar, "Workspace card below the row's middle",
        help: "The workspace hover card starts at its row's middle, leaving an empty slot beside the row's upper half that dismisses it, instead of lining its top up with the row's top.",
        default: false, code: "HoverCardEscapeGeometry.escapeSlotTunable")

    /// The alignment the sidebar uses now: top, or middle while the Debug Settings switch is on.
    public static var currentAlignment: RowAlignment { escapeSlotTunable.value ? .middle : .top }

    /// The card for `anchor` (a workspace's fill, or a group/rail band) at `size`,
    /// kept inside `visible` (the screen's visible frame, already inset by any margin) when given,
    /// its near edge `gap` (zero when nil, ``rowGap``) off the anchor's edge on
    /// device pixels of `scale`, lined up with the row by `alignment`.
    public init(anchor: CGRect, cardSize size: CGSize, visible: CGRect? = nil, scale: CGFloat = 2, gap: CGFloat? = nil,
                alignment: RowAlignment = .top) {
        var out = CmuxHoverEscapeGeometry()
        _ = cmux_hover_escape_geometry(CmuxHoverRect(anchor), size.width, size.height, visible != nil, CmuxHoverRect(visible ?? .zero),
                                       scale, gap != nil, gap ?? Self.rowGap, alignment == .middle ? 1 : 0, &out)
        self.anchor = out.anchor.cgRect
        card = out.card.cgRect
        escapeSlot = out.escape_slot.cgRect
        gapStrip = out.gap_strip.cgRect
        isLeading = out.is_leading
    }

    /// What `point` is: the card first, then the row, the slot and the gap.
    public func zone(at point: CGPoint) -> Zone {
        var geometry = CmuxHoverEscapeGeometry(anchor: CmuxHoverRect(anchor), card: CmuxHoverRect(card),
                                               escape_slot: CmuxHoverRect(escapeSlot), gap_strip: CmuxHoverRect(gapStrip),
                                               is_leading: isLeading)
        // 0 row, 1 card, 2 escape, 3 gap, 4 outside.
        switch cmux_hover_escape_zone(&geometry, CmuxHoverPoint(point)) {
        case 0: return .row
        case 1: return .card
        case 2: return .escape
        case 3: return .gap
        default: return .outside
        }
    }

    /// Whether the pointer at `point` keeps the card by where it is: on the row or on the card.
    /// In the gap only a pointer heading into the card keeps it (`HoverCardCoordinator`).
    public func keepsCard(at point: CGPoint) -> Bool {
        switch zone(at: point) {
        case .row, .card: true
        case .escape, .gap, .outside: false
        }
    }
}
