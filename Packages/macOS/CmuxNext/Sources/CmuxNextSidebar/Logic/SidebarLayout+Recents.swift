import CoreGraphics
import Foundation

// Projects and Recents (`sidebar.groupBy` = recents, off by default). Lawrence 2026-11-05: "similar thing in sidebar as
// chatgpt app, make it an option, basically u have projects/groups at the top, and show more, and you have recents as
// well". Every computer's groups list first under one "Projects" header: the first `projectLimit` top-level groups, then a
// "Show N more" row for the rest. Then every workspace in no group lists under one "Recents" header, the newest activity
// first. Pinned and the document's sections lay out as before. A filter and the session tree list every row in place, as
// before; Group by Status wins over it (`SidebarGrouping.groupsByRecents`). The list does not reorder by drag while it
// is on (`SidebarGrouping.isGrouped`).
nonisolated extension SidebarLayout {
    /// How many top-level groups Projects lists before its "Show N more" row (ChatGPT's sidebar shows five).
    static let projectLimit = 5

    /// The sidebar split for Projects and Recents.
    struct RecentsSplit {
        /// The sections with every computer's loose workspaces taken out, and the groups past the limit (with their
        /// subgroups) while Projects is folded. Order and ids unchanged.
        var sections: [SidebarSection]
        /// The loose workspaces, the newest activity first, each with its section and its index there.
        var recents: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)]
        /// The top-level groups the computers hold (listed or not).
        var projectCount: Int
        /// The top-level groups the folded Projects list leaves out (0 when it shows them all).
        var hiddenProjects: Int
        /// The person opened Projects past its limit: its row reads "Show fewer".
        var projectsOpened: Bool
    }

    /// Whether this layout draws Projects and Recents: on, and no filter or session tree.
    static func drawsRecents(_ o: SidebarLayoutOptions) -> Bool {
        o.grouping.groupsByRecents && o.filterMatches == nil && o.sessionTree == nil
    }

    /// Splits `sections` for Projects and Recents. A group holding the active workspace, or one that needs you, always lists.
    static func splittingRecents(_ sections: [SidebarSection], options o: SidebarLayoutOptions) -> RecentsSplit {
        var recents: [(ws: SidebarWorkspace, section: SidebarSection, index: Int)] = []
        var topGroups: [GroupID] = []
        var holdsActive = Set<GroupID>()
        for section in sections where section.machine != nil {
            var parents: [GroupID: GroupID] = [:]
            for node in section.nodes {
                guard case let .group(group) = node else { continue }
                if let parent = group.parent { parents[group.id] = parent } else { topGroups.append(group.id) }
                // The active row, or a row that needs you, keeps its group out of Show more (as the row limit does).
                guard group.workspaces.contains(where: { $0.id == o.activeWorkspaceID || $0.agentChip == .needsYou }) else { continue }
                // A subgroup's row keeps its top-level group listed (bounded: a bad parent cycle ends).
                var top = group.id
                for _ in 0..<64 { guard let parent = parents[top] else { break }; top = parent }
                holdsActive.insert(top)
            }
        }
        let opened = o.openShowMore.contains(.projects)
        // A list one group over the limit shows whole: a row that hides one group saves nothing.
        let folds = topGroups.count > projectLimit + 1
        var listed = Set(topGroups)
        if folds && !opened {
            listed = Set(topGroups.prefix(projectLimit)).union(holdsActive)
        }
        var split = RecentsSplit(sections: [], recents: [], projectCount: topGroups.count,
                                 hiddenProjects: topGroups.count - listed.count, projectsOpened: folds && opened)
        for section in sections {
            guard section.machine != nil else {
                split.sections.append(section)
                continue
            }
            var kept = section
            kept.nodes = []
            var dropped = Set<GroupID>()
            for (index, node) in section.nodes.enumerated() {
                switch node {
                case let .workspace(ws):
                    if o.visible(ws) { recents.append((ws, section, index)) }
                case let .group(group):
                    let hidden = group.parent.map(dropped.contains) ?? !listed.contains(group.id)
                    if hidden { dropped.insert(group.id) } else { kept.nodes.append(node) }
                case .item:
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

    /// One list's "Workspaces" heading row at `y`, over `section`'s `count` top-level rows.
    static func appendWorkspacesHeader(section: SectionID, count: Int, metrics m: SidebarLayoutMetrics,
                                       to rows: inout [SidebarRow], y: inout CGFloat) {
        rows.append(SidebarRow(
            key: .listHeader(.workspaces), y: y, height: m.groupHeaderHeight, section: section, group: nil, siblingIndex: 0,
            parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: count, groupColor: nil
        ))
        y += m.groupHeaderHeight + m.rowSpacing
    }

    /// Projects' "Show N more" row (or "Show fewer"), then the "Recents" header and its rows, at `y`.
    static func appendRecents(_ split: RecentsSplit, firstRow: Bool, options o: SidebarLayoutOptions, metrics m: SidebarLayoutMetrics,
                              to rows: inout [SidebarRow], y: inout CGFloat) {
        if split.hiddenProjects > 0 || split.projectsOpened {
            let h = m.height(for: WorkspaceRowContent())
            rows.append(SidebarRow(
                key: .showMore(.projects), y: y, height: h, section: SidebarDoneFoldID.projects.section, group: nil, siblingIndex: 0,
                parentIndex: nil, isLastInGroup: false, isCollapsed: !split.projectsOpened, childCount: split.hiddenProjects,
                groupColor: nil, content: WorkspaceRowContent()
            ))
            y += h + m.rowSpacing
        }
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
