package import CoreGraphics
package import CmuxNextSettings

/// The one rule for where a link or path the person opens from a pane lands (the app’s link opener):
/// a terminal's Cmd-click, a link in an agent chat, Home, a Markdown or code page, a `cmux://`
/// path link. The source pane never loses what it shows:
///
/// - ``LinkPlacement/splitRight`` (default) and ``LinkPlacement/newColumn``: with no pane right of
///   the source on its screen, a new split (or a new column) opens right of the source. With one,
///   the right column (`column`, when the caller measured it) places it by ``RightColumnPlacement``:
///   a split below that pane once, then tabs in the column's lower pane (Leo 2026-10-30: "if
///   there's already a thing on the right, there should be logic for just putting it on the lower
///   pane of the right"). A terminal or browser goes to a pane there that already holds its kind,
///   so only a different kind splits below (Leo 2026-10-31: "just open it on the existing").
///   Unmeasured, the pane on the right gets the tab.
/// - ``LinkPlacement/samePane``: a tab in the source pane, unless the source takes no new tabs.
///
/// A source that takes no tabs (Home's pinned dock) never holds the opened tab, whatever the
/// setting: the pane on its right, else ``Target/besideDock(_:)``. A split or column would make
/// the tab in the source first and then move it, and a pinned dock refuses that move, so the tab
/// stayed inside Home (Lawrence 2026-10-20).
///
/// `Pane` is the caller's pane identity (`LayoutPaneID` in the app), so the rule runs without a
/// window or a daemon.
package struct LinkOpenPlacement<Pane: Equatable> {
    /// Where the opened item goes.
    package enum Target: Equatable {
        /// A new tab in this existing pane.
        case pane(Pane)
        /// A new pane split off the right of this pane.
        case splitRight(of: Pane)
        /// A new pane split off the bottom of this pane, the right column's one pane.
        case splitBelow(of: Pane)
        /// A new column right of this pane's column.
        case newColumn(rightOf: Pane)
        /// Aimed at this pane, a pinned dock that takes no tabs (Home) with no pane on its right:
        /// the daemon opens it in a new column right of the dock (`pinned-dock-alone-v1`), so the
        /// dock never holds the tab, not even for the moment a split or column move would take.
        case besideDock(Pane)
        /// In the main pane layout, from an agent chat alone on its screen: the tab opens
        /// unselected in this pane, then the chat docks left and the tab's pane stays on its right.
        case dockChat(Pane)
    }

    package var setting: LinkPlacement

    /// Uses the caller's configured placement without reading shared settings.
    package init(setting: LinkPlacement) {
        self.setting = setting
    }

    /// Where an item opened from `source` lands. `takesTabs`: the source's strip takes new tabs;
    /// `right`: the pane right of the source on its screen, if any; `column`: the right column it
    /// is in, top to bottom, with `sourceWidth` and each pane's `width` (empty: not measured). `kind`:
    /// what opens, which `holds` matches against the column's panes (``RightColumnPlacement/Kind``).
    package func target(source: Pane, takesTabs: Bool, right: Pane?, column: [Pane] = [], sourceWidth: CGFloat? = nil,
                width: (Pane) -> CGFloat? = { _ in nil }, kind: RightColumnPlacement.Kind? = nil,
                holds: (Pane, RightColumnPlacement.Kind) -> Bool = { _, _ in false }) -> Target {
        if setting == .samePane, takesTabs { return .pane(source) }
        if let right, right != source {
            return Self.inColumn(right: right, column: column, sourceWidth: sourceWidth, width: width, kind: kind, holds: holds)
        }
        if !takesTabs { return .besideDock(source) }
        if setting == .newColumn { return .newColumn(rightOf: source) }
        // A split halves the source: one that would leave it under the chat floor is a tab in it
        // instead (RightColumnPlacement). A new column adds width to the strip, so it needs no floor.
        if case .tab = RightColumnPlacement.decide(sourceWidth: sourceWidth, column: [Pane](), width: width) { return .pane(source) }
        return .splitRight(of: source)
    }

    /// The panes whose tab for the same page an open selects instead of opening another, in order:
    /// the existing pane `target` opens in or below, then every pane of the source's right column
    /// (`column`), never the source. Review of #28044 at bd2b918d: with links A (upper) and B
    /// (lower) open, A again targets the lower pane, so looking only there opened a second A.
    /// An open that lands in the source itself (Same Pane, or a source too narrow to split) reuses
    /// nothing on the right: review of #28044 at c15e0d89, a Same Pane link focused its tab there.
    package static func reusePanes(target: Target, column: [Pane], source: Pane) -> [Pane] {
        if case .pane(let pane) = target, pane == source { return [] }
        var panes: [Pane] = []
        switch target {
        case .pane(let pane), .splitBelow(of: let pane): panes.append(pane)
        default: break
        }
        for pane in column where !panes.contains(pane) { panes.append(pane) }
        return panes.filter { $0 != source }
    }

    /// An item opened beside pane `right`, already on the source's right: ``RightColumnPlacement``
    /// over the measured `column` (a split below its one pane, else a tab in its lower pane), or a tab
    /// in `right` when the column was not measured. A `kind` a pane there already `holds` is a tab in
    /// that pane. Main pane layout's strip column uses it too.
    package static func inColumn(right: Pane, column: [Pane], sourceWidth: CGFloat?, width: (Pane) -> CGFloat?,
                         kind: RightColumnPlacement.Kind? = nil,
                         holds: (Pane, RightColumnPlacement.Kind) -> Bool = { _, _ in false }) -> Target {
        guard !column.isEmpty else { return .pane(right) }
        switch RightColumnPlacement.decide(sourceWidth: sourceWidth, column: column, width: width, opening: kind, holds: holds) {
        case .splitBelow(let pane): return .splitBelow(of: pane)
        case .tab(let pane): return .pane(pane ?? right)
        case .splitRight: return .pane(right)
        }
    }

    /// The pane right of `source` by layout order: `columns` are the screen's columns as the
    /// person sees them (each column's panes), `takesTabs` tells which panes take new tabs and
    /// `recency` lists panes newest first. The first column after the source's with a pane that
    /// takes tabs answers, with its most recent such pane (else its first). Nil when none.
    package static func paneRight(of source: Pane, columns: [[Pane]], takesTabs: (Pane) -> Bool, recency: [Pane]) -> Pane? {
        guard let index = columns.firstIndex(where: { $0.contains(source) }) else { return nil }
        for column in columns[(index + 1)...] {
            let candidates = column.filter { $0 != source && takesTabs($0) }
            guard let first = candidates.first else { continue }
            return recency.first(where: candidates.contains) ?? first
        }
        return nil
    }
}
