public import CoreGraphics

// The Needs you section (Leo 2026-11-10, design/sidebar.md "Per-project caps, infinite scroll and Needs you"): at the
// very top of the sidebar, only when something is in it, the yellow rows (waiting on you) then the blue ones (finished,
// unread) from every project and every loose workspace, at most 3, then "N more". It mirrors rows that also stay in
// place below. A click opens the row; it collapses like a project. Rust picks and orders the rows
// (`RustSidebarCaps.needsYou`); the model passes only the active rows and caches the answer by `sectionsRevision`
// (`SidebarModel+NeedsYouSection`). This file only draws them.

/// A row of the Needs you section (`SidebarRowKey.needsYou`).
public nonisolated enum SidebarNeedsYouRowKey: Hashable, Sendable {
    /// "Needs you": a click folds or opens the section.
    case header
    /// A mirror of workspace `id`'s row; its own row keeps `.workspace(id)` below.
    case row(WorkspaceID)
    /// "N more", or "Show less" once the section shows every row.
    case more
}

/// What the Needs you section draws (`SidebarLayoutOptions.needsYou`).
public nonisolated struct SidebarNeedsYouRows: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var workspace: SidebarWorkspace
        /// The section that lists it (its computer's name on the row, as in place).
        public var section: SectionID

        public init(workspace: SidebarWorkspace, section: SectionID) {
            (self.workspace, self.section) = (workspace, section)
        }
    }

    /// The rows drawn, yellow first, then blue (Rust's order).
    public var entries: [Entry] = []
    /// Rows behind "N more"; 0 when every row shows.
    public var more = 0
    /// The person pressed "N more": every row shows and the last row reads "Show less".
    public var isExpanded = false
    /// The person folded the section to its header.
    public var isFolded = false

    public init(entries: [Entry] = [], more: Int = 0, isExpanded: Bool = false, isFolded: Bool = false) {
        (self.entries, self.more, self.isExpanded, self.isFolded) = (entries, more, isExpanded, isFolded)
    }

    /// Every row in the section, drawn or behind "N more".
    public var total: Int { entries.count + more }
    public var isEmpty: Bool { total == 0 }
    /// The last row: "N more" while rows wait behind it, "Show less" once they show.
    var drawsMoreRow: Bool { more > 0 || isExpanded }
}

nonisolated extension SidebarLayout {
    /// Whether this layout draws the Needs you section: rows in it, and no filter (a match shows where it is), no
    /// session tree (its own needs-you tray, `SidebarNeedsYou`, lists what blocks you) and no Group by Status (its own
    /// Needs you section heads the list).
    static func drawsNeedsYouSection(_ o: SidebarLayoutOptions) -> Bool {
        guard let rows = o.needsYou, !rows.isEmpty else { return false }
        return o.filterMatches == nil && o.sessionTree == nil && !o.grouping.byStatus
    }

    /// The Needs you section's rows at `y`, the top of the list: its header, its rows unless folded, and its
    /// "N more" or "Show less" row. True when it drew anything.
    static func appendNeedsYouSection(_ sections: [SidebarSection], options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
                                      to rows: inout [SidebarRow], y: inout CGFloat) -> Bool {
        guard drawsNeedsYouSection(o), let section = o.needsYou else { return false }
        let headerSection = section.entries.first?.section ?? sections.first?.id ?? .pinned
        rows.append(SidebarRow(
            key: .needsYou(.header), y: y, height: m.groupHeaderHeight, section: headerSection, group: nil, siblingIndex: 0,
            parentIndex: nil, isLastInGroup: false, isCollapsed: section.isFolded, childCount: section.total, groupColor: nil
        ))
        y += m.groupHeaderHeight + m.rowSpacing
        guard !section.isFolded else { return true }
        for (index, entry) in section.entries.enumerated() {
            let listing = sections.first { $0.id == entry.section }
            let content = o.rowContent(entry.workspace, machine: listing.flatMap { machineLabel($0, options: o) })
            let h = m.height(for: content)
            rows.append(SidebarRow(
                key: .needsYou(.row(entry.workspace.id)), y: y, height: h, section: entry.section, group: nil, siblingIndex: index,
                parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil, content: content
            ))
            y += h + m.rowSpacing
        }
        if section.drawsMoreRow {
            let h = m.height(for: WorkspaceRowContent())
            // "N more" carries the rows behind it; expanded, it reads "Show less" (`isCollapsed` false).
            rows.append(SidebarRow(
                key: .needsYou(.more), y: y, height: h, section: headerSection, group: nil, siblingIndex: 0, parentIndex: nil,
                isLastInGroup: true, isCollapsed: !section.isExpanded, childCount: section.more, groupColor: nil
            ))
            y += h + m.rowSpacing
        }
        return true
    }
}
