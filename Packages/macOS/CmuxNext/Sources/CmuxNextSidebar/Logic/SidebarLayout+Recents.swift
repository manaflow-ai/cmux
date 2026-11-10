import CoreGraphics
import Foundation

// Projects and Recents (`sidebar.groupBy` = recents, off by default). Lawrence 2026-11-05: "similar thing in sidebar as
// chatgpt app, make it an option, basically u have projects/groups at the top, and show more, and you have recents as
// well". Every computer's groups list first under one "Projects" header, every project (Leo 2026-11-10: "there's obviously
// no show more for like all projects"; each project caps its own chats instead, `SidebarLayout+DoneFold`). Then every workspace in no group lists under one "Recents" header, the newest activity
// first. Pinned and the document's sections lay out as before. A filter and the session tree list every row in place, as
// before; Group by Status wins over it (`SidebarGrouping.groupsByRecents`). The list does not reorder by drag while it
// is on (`SidebarGrouping.isGrouped`).
nonisolated extension SidebarLayout {
    /// The sidebar split for Projects and Recents.
    struct RecentsSplit {
        /// The sections with every computer's loose workspaces taken out. Order and ids unchanged.
        var sections: [SidebarSection]
        /// The loose workspaces, the newest activity first, each with its section and its index there.
        var recents: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)]
        /// The top-level groups the computers hold (listed or not).
        var projectCount: Int
    }

    /// Whether this layout draws Projects and Recents: on, and no filter or session tree.
    static func drawsRecents(_ o: SidebarLayoutOptions) -> Bool {
        o.grouping.groupsByRecents && o.filterMatches == nil && o.sessionTree == nil
    }

    /// Splits `sections` for Projects and Recents.
    static func splittingRecents(_ sections: [SidebarSection], options o: SidebarLayoutOptions) -> RecentsSplit {
        var recents: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)] = []
        var projectCount = 0
        for section in sections where section.machine != nil {
            projectCount += section.nodes.count { if case let .group(group) = $0 { group.parent == nil } else { false } }
        }
        var split = RecentsSplit(sections: [], recents: [], projectCount: projectCount)
        for section in sections {
            guard section.machine != nil else {
                split.sections.append(section)
                continue
            }
            var kept = section
            kept.nodes = []
            for (index, node) in section.nodes.enumerated() {
                if case let .workspace(ws) = node {
                    if o.visible(ws) { recents.append((ws, section, index)) }
                } else {
                    kept.nodes.append(node)
                }
            }
            split.sections.append(kept)
        }
        split.recents = recents.enumerated().sorted { a, b in
            switch (a.element.ws.lastActivity, b.element.ws.lastActivity) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        return split
    }

    /// The "Projects" header row at `y`, over the first computer section that lists a group.
    static func appendProjectsHeader(_ split: RecentsSplit, section: SectionID, metrics m: SidebarLayoutMetrics,
                                     to rows: inout [SidebarRow], y: inout CGFloat) {
        rows.append(SidebarRow(
            key: .listHeader(.projects), y: y, height: m.groupHeaderHeight, section: section, group: nil, siblingIndex: 0,
            parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: split.projectCount, groupColor: nil
        ))
        y += m.groupHeaderHeight + m.rowSpacing
    }

    /// The "Recents" header and its rows, at `y`.
    static func appendRecents(_ split: RecentsSplit, firstRow: Bool, options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
                              to rows: inout [SidebarRow], y: inout CGFloat) {
        guard let first = split.recents.first else { return }
        if !firstRow { y += m.sectionSpacing }
        rows.append(SidebarRow(
            key: .listHeader(.recents), y: y, height: m.groupHeaderHeight, section: first.section.id, group: nil, siblingIndex: 0,
            parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: split.recents.count, groupColor: nil
        ))
        y += m.groupHeaderHeight + m.rowSpacing
        for member in split.recents {
            let content = o.rowContent(member.ws, machine: machineLabel(member.section, options: o))
            let h = m.height(for: content)
            rows.append(SidebarRow(
                key: .workspace(member.ws.id), y: y, height: h, section: member.section.id, group: nil, siblingIndex: member.index,
                parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil, content: content
            ))
            y += h + m.rowSpacing
        }
    }
}
