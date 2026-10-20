public import CoreGraphics
import Accelerate
import Foundation

/// Flattened sidebar: rows with frames, plus the live gap when dragging.
public nonisolated struct SidebarLayout: Hashable, Sendable {
    public private(set) var rows: [SidebarRow]
    /// Key to row index, so lookups stay O(1) with 10,000 workspaces, and a fold's splice rehashes no row.
    private var index: SidebarLayoutKeyIndex
    public var totalHeight: CGFloat
    /// Top of the open gap, if any.
    public var gapY: CGFloat?
    /// Height of the visible gap placeholder.
    public var gapHeight: CGFloat
    /// How far the gap pushes following rows down (height plus spacing).
    /// Pass this to `DropResolver.baseY(forDisplayY:gapY:gapHeight:)`.
    public var gapShift: CGFloat
    /// The spacing between consecutive rows. Hit testing gives it to the
    /// rows on either side, so rows tile and the pointer is never between
    /// two of them (Leo 2026-10-13: the hover flickered off in the gaps).
    public var rowSpacing: CGFloat = 0

    public init(rows: [SidebarRow], totalHeight: CGFloat, gapY: CGFloat?, gapHeight: CGFloat, gapShift: CGFloat) {
        self.rows = rows
        self.totalHeight = totalHeight
        self.gapY = gapY
        self.gapHeight = gapHeight
        self.gapShift = gapShift
        self.index = SidebarLayoutKeyIndex(rows: rows)
    }

    public static let empty = SidebarLayout(rows: [], totalHeight: 0, gapY: nil, gapHeight: 0, gapShift: 0)

    public func row(for key: SidebarRowKey) -> SidebarRow? { index.position(of: key).map { rows[$0] } }

    /// The position of `key`'s row in `rows`, or nil.
    func position(of key: SidebarRowKey) -> Int? { index.position(of: key) }

    /// Replaces `rows[range]` with `new` and moves every row after them by `dy` (a group's fold,
    /// `folding`): the cost is the replaced rows plus one move per later row; no key is hashed again.
    mutating func replaceRows(_ range: Range<Int>, with new: [SidebarRow], shiftingFollowingBy dy: CGFloat) {
        rows.replaceSubrange(range, with: new)
        if dy != 0 {
            Self.shiftY(of: &rows, from: range.lowerBound + new.count, by: dy)
            totalHeight += dy
        }
        index.splice(start: range.lowerBound, removed: range.count, inserted: new.map(\.key), rows: rows)
    }

    /// Moves the y of `rows[start...]` by `dy`: one strided vector add over the rows' `y` field (no row is
    /// copied), so a fold at 10,000 workspaces moves the rows below it in microseconds; a plain loop without it.
    private static func shiftY(of rows: inout [SidebarRow], from start: Int, by dy: CGFloat) {
        let count = rows.count - start
        guard count > 0 else { return }
        let stride = MemoryLayout<SidebarRow>.stride
        guard CGFloat.NativeType.self == Double.self, let offset = MemoryLayout<SidebarRow>.offset(of: \SidebarRow.y),
              stride % MemoryLayout<Double>.stride == 0, offset % MemoryLayout<Double>.alignment == 0 else {
            for i in start..<rows.count { rows[i].y += dy }
            return
        }
        var add = Double(dy)
        rows.withUnsafeMutableBytes { bytes in
            // crash-allow: `y` is a stored CGFloat (Double) at `offset` in each row, rows are `stride` bytes apart,
            // and the buffer holds `rows.count` rows; the add writes only those `count` doubles.
            guard let base = bytes.baseAddress else { return }
            let first = (base + start * stride + offset).assumingMemoryBound(to: Double.self)
            vDSP_vsaddD(first, vDSP_Stride(stride / MemoryLayout<Double>.stride), &add, first,
                        vDSP_Stride(stride / MemoryLayout<Double>.stride), vDSP_Length(count))
        }
    }

    /// Replaces the row at `position` with `row` of the same key and frame (a header's fold flag).
    mutating func setRow(_ row: SidebarRow, at position: Int) {
        rows[position] = row
    }

    // Equal layouts draw the same: the key index is how lookups are found, not what is drawn.
    public static func == (lhs: SidebarLayout, rhs: SidebarLayout) -> Bool {
        lhs.rows == rhs.rows && lhs.totalHeight == rhs.totalHeight && lhs.gapY == rhs.gapY && lhs.gapHeight == rhs.gapHeight
            && lhs.gapShift == rhs.gapShift && lhs.rowSpacing == rhs.rowSpacing
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rows)
        hasher.combine(totalHeight)
        hasher.combine(gapY)
        hasher.combine(gapHeight)
        hasher.combine(gapShift)
        hasher.combine(rowSpacing)
    }

    /// Replaces a workspace row's content in place, keeping its frame
    /// (a row update whose height is unchanged, `SidebarListView.patchRows`).
    mutating func setContent(_ content: WorkspaceRowContent, for key: SidebarRowKey) {
        guard let i = index.position(of: key) else { return }
        rows[i].content = content
    }

    /// Row whose hit area contains `y`, or nil in padding, a section or
    /// group gap, or the drop gap. A row's hit area is its frame plus half
    /// the `rowSpacing` to a neighbor on each side, so consecutive rows'
    /// hit areas meet; the pill stays inset in the frame.
    public func row(at y: CGFloat) -> SidebarRow? {
        guard let i = lastIndex(startingAtOrBefore: y) else { return nil }
        if y < rows[i].maxY { return rows[i] }
        guard i + 1 < rows.count else { return nil }
        let gap = rows[i + 1].y - rows[i].maxY
        guard gap > 0, gap <= rowSpacing else { return nil }
        return y < rows[i].maxY + gap / 2 ? rows[i] : rows[i + 1]
    }

    /// Index of the last row whose top is at or above `y` (rows are sorted
    /// by y). Binary search keeps hit testing O(log n).
    func lastIndex(startingAtOrBefore y: CGFloat) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].y <= y { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    public static func make(
        sections: [SidebarSection],
        metrics base: SidebarLayoutMetrics,
        options o: SidebarLayoutOptions = SidebarLayoutOptions()
    ) -> SidebarLayout {
        // Minimal mode is visibly compact: shorter rows, thin group headers (cx-7swgy).
        let m = o.minimal ? base.minimal : base
        // A new workspace's drop gap is a row: as short as minimal mode's rows.
        let gapHeight = max(0, o.gapHeight - (base.rowHeight - m.rowHeight))
        if o.hidesWorkspaces { return .empty }
        var rows: [SidebarRow] = []
        var y = m.topPadding
        var gapY: CGFloat?
        let filtering = o.filterMatches != nil
        // One machine needs no machine header: its name adds nothing.
        let machineCount = SidebarSection.machineCount(sections)
        // One list (cx-mdo0, Lawrence 2026-10-10: "just have linear list of
        // workspaces", like a browser): no "Projects" header and no computer
        // header or status row. A computer that cannot connect says so on its
        // workspaces' second line; the computer itself lives in Cloud/machines.
        // An empty computer shows nothing, unless no computer has a row (the
        // first one keeps its empty placeholder, a drop target).
        let listsAnyMachineRow = sections.contains { $0.machine != nil && !$0.nodes.isEmpty }
        var previousWasMachine = false
        // A block brings the band's own padding: the list's top padding goes after the blocks, as below the band.
        var previousWasBlock = false
        var shownEmptyMachine = false

        func visible(_ ws: SidebarWorkspace) -> Bool {
            !o.excludedWorkspaces.contains(ws.id) && (o.filterMatches?.contains(ws.id) ?? true)
        }

        // `showWorkspaceTabs` lists every workspace's tabs, except those
        // the user collapsed with the row's disclosure.
        func listsTabs(_ ws: SidebarWorkspace) -> Bool {
            o.showWorkspaceTabs && !o.collapsedWorkspaces.contains(ws.id)
        }

        func disclosure(_ ws: SidebarWorkspace) -> SidebarTabDisclosure? {
            guard o.showWorkspaceTabs else { return nil }
            if ws.tabs.isEmpty { return .empty }
            return o.collapsedWorkspaces.contains(ws.id) ? .collapsed : .expanded
        }

        func openGapIfNeeded(section: SectionID, group: GroupID?, index: Int) {
            guard gapY == nil, let gap = o.gap, gap.section == section, gap.group == group, gap.index == index else { return }
            gapY = y
            y += gapHeight + m.rowSpacing
        }

        var firstSection = true
        for section in sections {
            // Nodes that remain, with their visible children.
            var nodes: [(node: SidebarNode, children: [SidebarWorkspace])] = []
            // Nested groups (remote-groups-DESIGN.md slice 2) list flat, a group before its
            // subgroups: a group under a collapsed or hidden one hides too, and with a filter a
            // group shows while a group under it has a match (the path to the match).
            var hiddenGroups = Set<GroupID>()
            var pathToMatch = Set<GroupID>()
            if filtering {
                let parents = Dictionary(section.nodes.compactMap { node -> (GroupID, GroupID?)? in
                    if case let .group(group) = node { (group.id, group.parent) } else { nil }
                }, uniquingKeysWith: { first, _ in first })
                for node in section.nodes {
                    guard case let .group(group) = node, group.workspaces.contains(where: visible) else { continue }
                    var parent = group.parent
                    while let id = parent, pathToMatch.insert(id).inserted { parent = parents[id] ?? nil }
                }
            }
            for node in section.nodes {
                switch node {
                case let .workspace(ws):
                    if visible(ws) { nodes.append((node, [ws])) }
                case let .group(group):
                    if let parent = group.parent, hiddenGroups.contains(parent) {
                        hiddenGroups.insert(group.id)
                        continue
                    }
                    if group.id == o.excludedGroup {
                        hiddenGroups.insert(group.id)
                        continue
                    }
                    let children = group.workspaces.filter(visible)
                    // A group emptied by the drag keeps its header (it is a
                    // valid target); a group emptied by the filter hides.
                    if filtering && children.isEmpty && !pathToMatch.contains(group.id) {
                        hiddenGroups.insert(group.id)
                        continue
                    }
                    if group.isCollapsed && !filtering { hiddenGroups.insert(group.id) }
                    nodes.append((node, children))
                case let .item(item):
                    // A link or app row matches no workspace filter.
                    if !filtering && item.id != o.excludedItem { nodes.append((node, [])) }
                }
            }

            let isPinned = section.id == .pinned
            let gapHere = o.gap?.section == section.id
            if nodes.isEmpty && filtering { continue }
            if isPinned && nodes.isEmpty && !o.showEmptyPinned && !gapHere { continue }
            // A document section (sidebar-v2) draws its items in its own arrangement (one block row, its
            // region draws the header), then its groups as list rows; collapsed, only the block shows.
            let isDocSection = section.isDocSection
            var docID: String?
            if case let .custom(custom) = section.kind { docID = custom.id }
            let blockHeight = docID.flatMap { o.blockHeights[$0] } ?? 0
            if let docID, o.collapsedDocSections.contains(docID) { nodes = [] }
            let emptyDropZone = docID != nil && o.showEmptyPinned && !filtering // any document section takes a drop during a drag
            if isDocSection && nodes.isEmpty && blockHeight == 0 && !gapHere && !emptyDropZone { continue }

            // A remote group (remote-groups-DESIGN.md slice 4) is a section of its own in one list too.
            let flat = o.flattensMachines && section.machine != nil && !section.isHostGroup
            if flat && nodes.isEmpty && !gapHere && (listsAnyMachineRow || shownEmptyMachine) { continue }
            if flat && nodes.isEmpty { shownEmptyMachine = true }
            // Consecutive computers in one list read as one list: no gap. A block brings its own padding.
            if firstSection && blockHeight > 0 { y -= m.topPadding }
            if !firstSection && !(flat && previousWasMachine) && blockHeight == 0 { y += previousWasBlock ? m.topPadding : m.sectionSpacing }
            firstSection = false
            previousWasBlock = blockHeight > 0 && nodes.isEmpty
            previousWasMachine = section.machine != nil
            if let docID, blockHeight > 0 {
                rows.append(SidebarRow(
                    key: .block(docID), y: y, height: blockHeight, section: section.id,
                    group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: false, childCount: 0, groupColor: nil
                ))
                y += blockHeight
            }
            // Headers stay for the pinned area and for one section per
            // computer (`sidebar.groupByComputer`, opt-in), never in one list.
            let showsHeader = !isDocSection && (section.machine == nil || section.isHostGroup
                || (!flat && (machineCount > 1 || o.showsSoleMachineHeader)))
            // The computer a row names in one list (never this Mac), with its
            // status when it cannot connect.
            let machineLabel = Self.machineLabel(section, options: o)
            // Without a header there is nothing to expand it from: a list the
            // old "Projects" header folded shows again.
            let collapsed = showsHeader && section.isCollapsed && !filtering
            if showsHeader {
                rows.append(SidebarRow(
                    key: .section(section.id), y: y, height: m.sectionHeaderHeight, section: section.id,
                    group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: collapsed, childCount: nodes.count, groupColor: nil,
                    titlesProjects: section.machine != nil && machineCount == 1
                ))
                y += m.sectionHeaderHeight + m.rowSpacing
            }
            if collapsed { continue }

            if nodes.isEmpty {
                if gapHere {
                    openGapIfNeeded(section: section.id, group: nil, index: 0)
                } else if blockHeight == 0 || (emptyDropZone && docID.map(o.emptyDocSections.contains) == true) {
                    rows.append(SidebarRow(
                        key: .emptySection(section.id), y: y, height: m.emptySectionHeight, section: section.id,
                        group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil
                    ))
                    y += m.emptySectionHeight + m.rowSpacing
                }
                continue
            }

            // One node at its model index (drops resolve by it, whatever the drawn order).
            func emit(_ index: Int, _ entry: (node: SidebarNode, children: [SidebarWorkspace])) {
                openGapIfNeeded(section: section.id, group: nil, index: index)
                switch entry.node {
                case let .workspace(ws):
                    let content = o.rowContent(ws, machine: machineLabel)
                    let h = m.height(for: content)
                    rows.append(SidebarRow(
                        key: .workspace(ws.id), y: y, height: h, section: section.id,
                        group: nil, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil,
                        tabDisclosure: disclosure(ws), content: content
                    ))
                    y += h + m.rowSpacing
                    if listsTabs(ws) {
                        for tab in ws.tabs {
                            rows.append(SidebarRow(
                                key: .tab(ws.id, tab.id), y: y, height: m.tabRowHeight, section: section.id,
                                group: nil, workspace: ws.id, siblingIndex: 0, parentIndex: nil,
                                isLastInGroup: false, isCollapsed: false, childCount: 0,
                                groupColor: nil, tabKind: tab.kind
                            ))
                            y += m.tabRowHeight + m.rowSpacing
                        }
                    }
                case let .item(item):
                    let content = WorkspaceRowContent() // one line, as a compact workspace row
                    let h = m.height(for: content)
                    rows.append(SidebarRow(
                        key: .item(item.id), y: y, height: h, section: section.id,
                        group: nil, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: false, childCount: 0, groupColor: nil, content: content
                    ))
                    y += h + m.rowSpacing
                case let .group(group):
                    // The member rows in document order: workspaces with the group's link, tab and app items
                    // (an item matches no workspace filter; a dragged item leaves its slot).
                    let shown = Set(entry.children.map(\.id))
                    let members = group.members.filter { member in
                        switch member {
                        case let .workspace(ws): shown.contains(ws.id)
                        case let .item(item): !filtering && item.id != o.excludedItem
                        }
                    }
                    let groupCollapsed = group.isCollapsed && !filtering
                    var header = SidebarRow(
                        key: .group(group.id), y: y, height: m.groupHeaderHeight, section: section.id,
                        group: group.id, siblingIndex: index, parentIndex: nil, isLastInGroup: false,
                        isCollapsed: groupCollapsed, childCount: members.count, groupColor: group.color
                    )
                    header.depth = group.depth
                    rows.append(header)
                    // Every row appended below is this group's member: one level in from its header.
                    let memberRowsStart = rows.count
                    defer { for i in memberRowsStart..<rows.count { rows[i].depth = group.depth + 1 } }
                    y += m.groupHeaderHeight + m.rowSpacing
                    if groupCollapsed {
                        // Keep the selected workspace as the one visible member
                        // of a collapsed group. This preserves orientation and
                        // selection without reopening the rest of the group.
                        guard let activeID = o.activeWorkspaceID,
                              let childIndex = members.firstIndex(where: { if case let .workspace(ws) = $0 { ws.id == activeID } else { false } }),
                              let ws = entry.children.first(where: { $0.id == activeID }) else { return }
                        let content = o.rowContent(ws, machine: machineLabel)
                        let h = m.height(for: content)
                        rows.append(SidebarRow(
                            key: .workspace(ws.id), y: y, height: h, section: section.id,
                            group: group.id, siblingIndex: childIndex, parentIndex: index,
                            isLastInGroup: true, isCollapsed: false, childCount: 0,
                            groupColor: group.color, tabDisclosure: disclosure(ws), content: content
                        ))
                        y += h + m.rowSpacing
                        return
                    }
                    for (childIndex, member) in members.enumerated() {
                        openGapIfNeeded(section: section.id, group: group.id, index: childIndex)
                        guard case let .workspace(ws) = member else {
                            guard case let .item(item) = member else { continue }
                            // A link, tab or app member: the listed item's row (`.item`), indented under the group's line.
                            let content = WorkspaceRowContent()
                            let h = m.height(for: content)
                            rows.append(SidebarRow(
                                key: .item(item.id), y: y, height: h, section: section.id,
                                group: group.id, siblingIndex: childIndex, parentIndex: index,
                                isLastInGroup: childIndex == members.count - 1,
                                isCollapsed: false, childCount: 0, groupColor: group.color, content: content
                            ))
                            y += h + m.rowSpacing
                            continue
                        }
                        let content = o.rowContent(ws, machine: machineLabel)
                        let h = m.height(for: content)
                        rows.append(SidebarRow(
                            key: .workspace(ws.id), y: y, height: h, section: section.id,
                            group: group.id, siblingIndex: childIndex, parentIndex: index,
                            isLastInGroup: childIndex == members.count - 1,
                            isCollapsed: false, childCount: 0, groupColor: group.color,
                            tabDisclosure: disclosure(ws), content: content
                        ))
                        y += h + m.rowSpacing
                        if listsTabs(ws) {
                            for tab in ws.tabs {
                                rows.append(SidebarRow(
                                    key: .tab(ws.id, tab.id), y: y, height: m.tabRowHeight, section: section.id,
                                    group: group.id, workspace: ws.id, siblingIndex: childIndex, parentIndex: index,
                                    isLastInGroup: false, isCollapsed: false, childCount: 0,
                                    groupColor: group.color, tabKind: tab.kind
                                ))
                                y += m.tabRowHeight + m.rowSpacing
                            }
                        }
                    }
                    openGapIfNeeded(section: section.id, group: group.id, index: members.count)
                    y += m.groupBottomPadding
                }
            }
            // Group by Folder lists groups and document items (links, tabs, apps) as they are.
            func isGroup(_ entry: (node: SidebarNode, children: [SidebarWorkspace])) -> Bool {
                if case .workspace = entry.node { false } else { true }
            }

            let byFolder = o.groupsByFolder && section.machine != nil && machineCount == 1 && !filtering
            guard byFolder else {
                for (index, entry) in nodes.enumerated() { emit(index, entry) }
                openGapIfNeeded(section: section.id, group: nil, index: nodes.count)
                continue
            }
            // Group by Folder: groups as they were, then a header per folder
            // over its loose rows, folders in first-seen order, "no folder" last.
            for (index, entry) in nodes.enumerated() where isGroup(entry) { emit(index, entry) }
            var folders: [String] = []
            var members: [String: [Int]] = [:]
            for (index, entry) in nodes.enumerated() {
                guard case let .workspace(ws) = entry.node else { continue }
                let folder = ws.folder ?? ""
                if members[folder] == nil { folders.append(folder) }
                members[folder, default: []].append(index)
            }
            if let none = folders.firstIndex(of: ""), none != folders.count - 1 { folders.append(folders.remove(at: none)) }
            for folder in folders {
                let indices = members[folder] ?? []
                rows.append(SidebarRow(
                    key: .folder(section.id, folder), y: y, height: m.groupHeaderHeight, section: section.id,
                    group: nil, siblingIndex: 0, parentIndex: nil, isLastInGroup: false,
                    isCollapsed: false, childCount: indices.count, groupColor: nil
                ))
                y += m.groupHeaderHeight + m.rowSpacing
                for index in indices { emit(index, nodes[index]) }
                y += m.groupBottomPadding
            }
            openGapIfNeeded(section: section.id, group: nil, index: nodes.count)
        }
        y += m.bottomPadding
        var layout = SidebarLayout(
            rows: rows, totalHeight: y, gapY: gapY,
            gapHeight: gapY == nil ? 0 : gapHeight,
            gapShift: gapY == nil ? 0 : gapHeight + m.rowSpacing
        )
        layout.rowSpacing = m.rowSpacing
        return layout
    }
}
