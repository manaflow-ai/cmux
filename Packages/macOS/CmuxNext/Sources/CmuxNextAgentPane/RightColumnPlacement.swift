public import CmuxNextDaemon
public import CoreGraphics

/// The one rule for what opens on the right of a pane: transcript subagents (``AgentSubagentPanes``),
/// side chats, Session Info sessions and transcript session cards (``AgentSidePanes``), and links
/// opened to the right (the app's `LinkOpener`). leo-workspace design/pane-placement.md; Leo
/// 2026-10-30: "subagent stuff... or anything we expect to open on "the right"... if there's
/// already a thing on the right, there should be logic for just putting it on the lower pane of the
/// right. that kinda split."
///
/// - Nothing on the right: a new split right of the source.
/// - A terminal or browser, with a pane on the right that already holds that kind: a tab in that
///   pane (the lowest such one), never a split. Leo 2026-10-31, of a link that split under the
///   browser pane already on the right: "imo in this case, just open it on the existing. you only
///   need the rightmost botom auto split when there's a terminal that gets opened when there's
///   already a browser, and vice versa".
/// - A document (the Changes viewer's diff, an edited-files card's View changes): a tab in the pane
///   on the right that already shows a diff, else in the lowest pane on the right, never a lower
///   split; with nothing there a split right (half the chat), whatever the width floors say. It never
///   opens over the chat, in its pane or its page. Leo 2026-11-03, of the Changes viewer: "just put
///   it in a tab???"; Lawrence 2026-11-03: "clicking view changes needs to open diff in pane split
///   right". The diff tab itself is reused (DiffPageService: one per repository, one chat patch tab
///   per window), so a second click on the same edit selects the tab it opened.
/// - One pane on the right: a new split below it, the right column's lower pane. What the right
///   pane shows stays; closing the lower pane's last tab collapses the split back.
/// - Two or more: a tab in the lowest pane, never another split.
///
/// No split leaves the source under ``minimumChatWidth`` or the right column under
/// ``minimumRightColumnWidth``: that open is a tab in the pane on the right, or in the source's own
/// pane when there is none.
public struct RightColumnPlacement {
    public init() {}
    /// The narrowest the source (the chat) stays after a split.
    public static let minimumChatWidth: CGFloat = 480
    /// The narrowest the right column may be for a split in it.
    public static let minimumRightColumnWidth: CGFloat = 420

    /// What an open shows, for the same-kind rule: only the two kinds Leo named, and a document,
    /// which is a tab in any pane on the right. Anything else (a chat, a subagent, a file page) opens
    /// with no kind and splits as before.
    public enum Kind: Sendable, Hashable {
        case terminal
        case browser
        case document
    }

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
        /// The kinds of tab each pane holds.
        public var kinds: [String: Set<Kind>]

        public init(sourceWidth: CGFloat? = nil, panes: [String] = [], widths: [String: CGFloat] = [:], kinds: [String: Set<Kind>] = [:]) {
            self.sourceWidth = sourceWidth
            self.panes = panes
            self.widths = widths
            self.kinds = kinds
        }
    }

    /// Decides for `column` an open of `kind` (nil: no kind); `holds` says whether a pane already
    /// holds a tab of a kind. An unknown width sets no floor.
    public static func decide<Pane>(sourceWidth: CGFloat?, column: [Pane], width: (Pane) -> CGFloat?, opening kind: Kind? = nil,
                                    holds: (Pane, Kind) -> Bool = { _, _ in false }) -> Decision<Pane> {
        // A document never stays in the source's pane, so the chat is never what it replaces.
        // The pane already showing a diff first, so diffs gather in one pane; else the lowest.
        if kind == .document { return (column.last { holds($0, .document) } ?? column.last).map { .tab($0) } ?? .splitRight }
        guard let right = column.first else {
            // A split right halves the source: both halves must stay wide enough.
            let fits = sourceWidth.map { $0 / 2 >= minimumChatWidth && $0 / 2 >= minimumRightColumnWidth } ?? true
            return fits ? .splitRight : .tab(nil)
        }
        if let kind, let same = column.last(where: { holds($0, kind) }) { return .tab(same) }
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

    /// ``decide(sourceWidth:column:width:opening:holds:)`` for a column the app measured.
    public static func decide(_ column: Column, opening kind: Kind? = nil) -> Decision<String> {
        decide(sourceWidth: column.sourceWidth, column: column.panes, width: { column.widths[$0] }, opening: kind,
               holds: { column.kinds[$0]?.contains($1) == true })
    }
}

public extension RightColumnPlacement.Kind {
    /// The kind of an existing tab that opens beside a chat: a browser, a local terminal, or a
    /// document (`document`: the tab shows the Changes diff page); nil for anything else, a remote
    /// terminal included.
    init?(opening tab: TabKind, document: Bool) {
        switch tab {
        case .browser: self = .browser
        case .pty: self = .terminal
        default:
            guard document else { return nil }
            self = .document
        }
    }
}

public extension RightColumnPlacement.Kind {
    /// Whether `tab` makes its pane hold this kind for the same-kind rule: a local or remote terminal,
    /// a browser tab, or (`document`: the tab shows the Changes diff page) a diff.
    func isHeld(by tab: TabModel, document: Bool) -> Bool {
        switch (self, tab.kind) {
        case (.terminal, .pty), (.terminal, .remoteTerminal), (.browser, .browser): true
        case (.document, _): document
        default: false
        }
    }
}

extension RightColumnPlacement.Decision: Sendable where Pane: Sendable {}
