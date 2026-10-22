import CmuxNextSettings

/// The one rule for where a link or path the person opens from a pane lands (``LinkOpener``):
/// a terminal's Cmd-click, a link in an agent chat, Home, a Markdown or code page, a `cmux://`
/// path link. The source pane never loses what it shows:
///
/// - ``LinkPlacement/splitRight`` (default) and ``LinkPlacement/newColumn``: the pane right of
///   the source on its screen gets the new tab, so repeated opens reuse one pane; with no pane
///   there, a new split (or a new column) opens right of the source.
/// - ``LinkPlacement/samePane``: a tab in the source pane, unless the source takes no new tabs.
///
/// A source that takes no tabs (Home's pinned dock) never holds the opened tab, whatever the
/// setting: the pane on its right, else ``Target/besideDock(_:)``. A split or column would make
/// the tab in the source first and then move it, and a pinned dock refuses that move, so the tab
/// stayed inside Home (Lawrence 2026-10-20).
///
/// `Pane` is the caller's pane identity (`LayoutPaneID` in the app), so the rule runs without a
/// window or a daemon.
struct LinkOpenPlacement<Pane: Equatable> {
    /// Where the opened item goes.
    enum Target: Equatable {
        /// A new tab in this existing pane.
        case pane(Pane)
        /// A new pane split off the right of this pane.
        case splitRight(of: Pane)
        /// A new column right of this pane's column.
        case newColumn(rightOf: Pane)
        /// Aimed at this pane, a pinned dock that takes no tabs (Home) with no pane on its right:
        /// the daemon opens it in a new column right of the dock (`pinned-dock-alone-v1`), so the
        /// dock never holds the tab, not even for the moment a split or column move would take.
        case besideDock(Pane)
        /// Main pane layout (``MainPaneLayout``), from an agent chat alone on its screen: the tab opens
        /// unselected in this pane, then the chat docks left and the tab's pane stays on its right.
        case dockChat(Pane)
    }

    var setting: LinkPlacement

    /// Where an item opened from `source` lands. `takesTabs`: the source's strip takes new tabs;
    /// `right`: the pane right of the source on its screen, if any.
    func target(source: Pane, takesTabs: Bool, right: Pane?) -> Target {
        if setting == .samePane, takesTabs { return .pane(source) }
        if let right, right != source { return .pane(right) }
        if !takesTabs { return .besideDock(source) }
        return setting == .newColumn ? .newColumn(rightOf: source) : .splitRight(of: source)
    }

    /// The pane right of `source` by layout order: `columns` are the screen's columns as the
    /// person sees them (each column's panes), `takesTabs` tells which panes take new tabs and
    /// `recency` lists panes newest first. The first column after the source's with a pane that
    /// takes tabs answers, with its most recent such pane (else its first). Nil when none.
    static func paneRight(of source: Pane, columns: [[Pane]], takesTabs: (Pane) -> Bool, recency: [Pane]) -> Pane? {
        guard let index = columns.firstIndex(where: { $0.contains(source) }) else { return nil }
        for column in columns[(index + 1)...] {
            let candidates = column.filter { $0 != source && takesTabs($0) }
            guard let first = candidates.first else { continue }
            return recency.first(where: candidates.contains) ?? first
        }
        return nil
    }
}
