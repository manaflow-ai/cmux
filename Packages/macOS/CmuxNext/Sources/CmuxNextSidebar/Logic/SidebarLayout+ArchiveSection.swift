import CoreGraphics

// The Archive section (Lawrence 19197: "i see a ton of archived ... this doesnt look very clean ... maybe we can move
// completely archived groups into archive as well"): every archived workspace, and every group that is archived or
// whose workspaces are all archived, leaves its list for one "Archive (N)" row at the bottom of the sidebar, closed by
// default. Opened, the row lists them under it, dimmed: whole groups and loose archived workspaces in document order,
// then archived members of groups that stay. No list draws an "Archived (N)" row of its own. The active
// workspace keeps its place (a click moves no row); a filter, the session tree and Group by Status list every row in
// place, as before.
nonisolated extension SidebarLayout {
    /// The sidebar split for the Archive section: what the lists draw, what the archive holds, and its count.
    struct ArchiveSplit {
        /// The sections without their archived rows and archived groups (their order and ids unchanged).
        var live: [SidebarSection]
        /// Per section with archived rows, a copy holding only them: whole groups and loose workspaces in document
        /// order, then archived members of groups that stay, as loose rows.
        var archived: [SidebarSection]
        /// The archived workspaces the archive holds (members of archived groups included).
        var count: Int
    }

    /// Whether this layout draws the Archive section: on, and no filter, session tree or Group by Status.
    static func drawsArchiveSection(_ o: SidebarLayoutOptions) -> Bool {
        o.archiveSection && o.filterMatches == nil && o.sessionTree == nil && !o.grouping.byStatus
    }

    /// Splits `sections` for the Archive section; `active` keeps its place in its list.
    static func splittingArchive(_ sections: [SidebarSection], keeping active: WorkspaceID?) -> ArchiveSplit {
        var split = ArchiveSplit(live: [], archived: [], count: 0)
        for section in sections {
            // Pinned holds no groups and its rows are the person's picks: it keeps them.
            guard section.id != .pinned, section.id != .custom(SidebarDocStore.pinnedSection) else {
                split.live.append(section)
                continue
            }
            var live = section, held = section, loose: [SidebarNode] = []
            (live.nodes, held.nodes, held.isCollapsed) = ([], [], false)
            // A moved group's subgroups move with it; the depth it had is taken off theirs.
            var movedDepth: [GroupID: Int] = [:]
            for node in section.nodes {
                switch node {
                case let .workspace(ws):
                    if ws.isArchived && ws.id != active {
                        held.nodes.append(node)
                        split.count += 1
                    } else {
                        live.nodes.append(node)
                    }
                case let .item(item):
                    if item.isArchived { held.nodes.append(node) } else { live.nodes.append(node) }
                case var .group(group):
                    let holdsActive = active.map { id in group.workspaces.contains { $0.id == id } } ?? false
                    let parentMoved = group.parent.flatMap { movedDepth[$0] }
                    let allArchived = !group.workspaces.isEmpty && group.workspaces.allSatisfy(\.isArchived)
                    if !holdsActive && (parentMoved != nil || group.isArchived || allArchived) {
                        let shift = parentMoved ?? group.depth
                        movedDepth[group.id] = shift
                        if parentMoved == nil { group.parent = nil }
                        group.depth -= shift
                        held.nodes.append(.group(group))
                        split.count += group.workspaces.count
                        continue
                    }
                    let gone = group.workspaces.filter { $0.isArchived && $0.id != active }
                    if !gone.isEmpty {
                        group.workspaces.removeAll { $0.isArchived && $0.id != active }
                        loose += gone.map(SidebarNode.workspace)
                        split.count += gone.count
                    }
                    live.nodes.append(.group(group))
                }
            }
            held.nodes += loose
            split.live.append(live)
            if !held.nodes.isEmpty { split.archived.append(held) }
        }
        return split
    }

    /// Appends the "Archive (N)" row at `y` and, opened, the archived rows under it (laid out as their own sidebar,
    /// without the headers and fold rows the lists above already draw). Nothing when nothing is archived. A drag
    /// keeps it closed: its rows take no drop.
    static func appendArchive(_ split: ArchiveSplit, firstRow: Bool, options o: SidebarLayoutOptions, base: SidebarLayoutMetrics,
                              metrics m: SidebarLayoutMetrics, to rows: inout [SidebarRow], y: inout CGFloat) {
        guard !split.archived.isEmpty else { return }
        if !firstRow { y += m.sectionSpacing }
        let open = o.openDoneFolds.contains(.archive) && o.gap == nil && !o.showEmptyPinned
        let h = m.height(for: WorkspaceRowContent())
        rows.append(SidebarRow(
            key: .doneFold(.archive), y: y, height: h, section: SidebarDoneFoldID.archive.section, group: nil, siblingIndex: 0,
            parentIndex: nil, isLastInGroup: false, isCollapsed: !open, childCount: split.count, groupColor: nil,
            content: WorkspaceRowContent()
        ))
        y += h + m.rowSpacing
        guard open else { return }
        var inner = o
        (inner.archiveSection, inner.foldsArchived, inner.foldsDone, inner.rowLimit) = (false, false, false, 0)
        (inner.gap, inner.chatHistory, inner.blockHeights, inner.collapsedDocSections) = (nil, nil, [:], [])
        let nested = make(sections: split.archived, metrics: base, options: inner)
        let dy = y - m.topPadding
        for var row in nested.rows {
            switch row.key {
            case .section, .emptySection, .block, .folder, .status, .doneFold, .showMore: continue
            default:
                row.y += dy
                rows.append(row)
                y = row.maxY + m.rowSpacing
            }
        }
    }
}
