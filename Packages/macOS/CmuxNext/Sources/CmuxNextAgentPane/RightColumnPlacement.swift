public import CoreGraphics

/// The one rule for what opens on the right of a pane: transcript subagents (``AgentSubagentPanes``),
/// side chats, Session Info sessions and transcript session cards (``AgentSidePanes``), and links
/// opened to the right (the app's `LinkOpener`). leo-workspace design/pane-placement.md; Leo
/// 2026-10-30: "subagent stuff... or anything we expect to open on "the right"... if there's
/// already a thing on the right, there should be logic for just putting it on the lower pane of the
/// right. that kinda split."
///
/// - Nothing on the right: a new split right of the source.
/// - One pane on the right: a new split below it, the right column's lower pane. What the right
///   pane shows stays; closing the lower pane's last tab collapses the split back.
/// - Two or more: a tab in the lowest pane, never another split.
///
/// No split leaves the source under ``minimumChatWidth`` or the right column under
/// ``minimumRightColumnWidth``: that open is a tab in the pane on the right, or in the source's own
/// pane when there is none.
public enum RightColumnPlacement {
    /// The narrowest the source (the chat) stays after a split.
    public static let minimumChatWidth: CGFloat = 480
    /// The narrowest the right column may be for a split in it.
    public static let minimumRightColumnWidth: CGFloat = 420

    /// Where the item opens. `Pane` is the caller's pane identity.
    public enum Decision<Pane: Equatable>: Equatable {
        /// A new split right of the source.
        case splitRight
        /// A new split below this pane, the right column's one pane.
        case splitBelow(Pane)
        /// A tab in this pane; nil: the source's own pane.
        case tab(Pane?)
    }

    /// The source's width and the right column beside it, top to bottom, with each pane's width.
    public struct Column: Equatable, Sendable {
        public var sourceWidth: CGFloat?
        public var panes: [String]
        public var widths: [String: CGFloat]

        public init(sourceWidth: CGFloat? = nil, panes: [String] = [], widths: [String: CGFloat] = [:]) {
            self.sourceWidth = sourceWidth
            self.panes = panes
            self.widths = widths
        }
    }

    /// Decides for `column`; an unknown width sets no floor.
    public static func decide<Pane>(sourceWidth: CGFloat?, column: [Pane], width: (Pane) -> CGFloat?) -> Decision<Pane> {
        guard let right = column.first else {
            // A split right halves the source: both halves must stay wide enough.
            let fits = sourceWidth.map { $0 / 2 >= minimumChatWidth && $0 / 2 >= minimumRightColumnWidth } ?? true
            return fits ? .splitRight : .tab(nil)
        }
        if column.count > 1 { return .tab(column.last) }
        let fits = (sourceWidth.map { $0 >= minimumChatWidth } ?? true) && (width(right).map { $0 >= minimumRightColumnWidth } ?? true)
        return fits ? .splitBelow(right) : .tab(right)
    }

    /// The right column beside `source` from pane frames in one top-down (flipped) space: the panes
    /// whose left edge is the nearest one at or past the source's right edge (within `gap`, the
    /// layout's gutter) and that overlap the source's height, top to bottom. Geometry only, so a
    /// column of several panes reads the same whichever of them was focused last.
    public static func column<Pane: Hashable>(beside source: Pane, frames: [Pane: CGRect], gap: CGFloat = 24) -> [Pane] {
        guard let origin = frames[source] else { return [] }
        let beside = frames.filter { pane, rect in
            pane != source && rect.minX >= origin.maxX - 1 && rect.minY < origin.maxY && rect.maxY > origin.minY
        }
        guard let nearest = beside.values.map(\.minX).min(), nearest - origin.maxX <= gap else { return [] }
        return beside.filter { abs($0.value.minX - nearest) <= 1 }.sorted { $0.value.minY < $1.value.minY }.map(\.key)
    }

    /// ``decide(sourceWidth:column:width:)`` for a column the app measured.
    public static func decide(_ column: Column) -> Decision<String> {
        decide(sourceWidth: column.sourceWidth, column: column.panes, width: { column.widths[$0] })
    }
}

extension RightColumnPlacement.Decision: Sendable where Pane: Sendable {}
