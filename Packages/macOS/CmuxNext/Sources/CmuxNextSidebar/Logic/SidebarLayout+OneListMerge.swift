import CoreGraphics
import Foundation

/// One list is chronological across computers (plans/cmux-next/remote-groups-per-machine-DESIGN.md R3).
///
/// `make` lays out each computer's section on its own; consecutive headerless computer sections then
/// read as one list, machine after machine. This pass interleaves them: the run's top-level units (a
/// workspace with its tab and tree rows, a group with its members, a fold row) merge newest first by
/// each workspace's `createdMs`, in a stable k-way merge of each section's own order, so a person's
/// Move to Top or drag on one computer is never undone. A unit without a time takes the time of the
/// unit above it in its own section (the first one sorts first), so a document made before the
/// daemon stamped times keeps today's order. Every row keeps its section and index, so drops, folds
/// and row updates still name the right place; only `y` moves. Cost: O(rows + units × sections).
nonisolated extension SidebarLayout {
    /// One top-level unit of a run: its rows (`range` in `rows`), where it started, its height with
    /// the spacing after it, its section and its merge key.
    private struct MergeUnit {
        var range: Range<Int>
        var start: CGFloat
        var span: CGFloat
        var section: SectionID
        var key: UInt64
        /// The unit is a group whose members hold the drop gap.
        var holdsGap = false
    }

    /// Interleaves each run of consecutive `flat` computer sections in `rows` by creation time.
    /// `gapY` is the open drop gap's top (moved with its place); `gap` names that place.
    /// `created`: each workspace's `createdMs`.
    static func mergeOneList(_ rows: inout [SidebarRow], flat: Set<SectionID>, created: [WorkspaceID: UInt64], gap: DropPosition?,
                             gapY: inout CGFloat?, gapShift: CGFloat, metrics m: SidebarLayoutMetrics) {
        guard flat.count > 1 else { return }
        var i = 0
        while i < rows.count {
            guard flat.contains(rows[i].section) else { i += 1; continue }
            var end = i
            var sections: [SectionID] = []
            while end < rows.count, flat.contains(rows[end].section) {
                if sections.last != rows[end].section { sections.append(rows[end].section) }
                end += 1
            }
            if Set(sections).count > 1 { mergeRun(&rows, i..<end, created: created, gap: gap, gapY: &gapY, gapShift: gapShift, metrics: m) }
            i = end
        }
    }

    /// Whether `row` starts a top-level unit (not a member, a nested group, a tab or a tree child).
    private static func startsUnit(_ row: SidebarRow) -> Bool {
        if case .tab = row.key { return false }
        return row.parentIndex == nil && row.depth == 0 && (row.content?.treeDepth ?? 0) == 0
    }

    private static func mergeRun(_ rows: inout [SidebarRow], _ run: Range<Int>, created: [WorkspaceID: UInt64], gap: DropPosition?, gapY: inout CGFloat?,
                                 gapShift: CGFloat, metrics m: SidebarLayoutMetrics) {
        // The units, in each section's order.
        var units: [MergeUnit] = []
        for index in run {
            if startsUnit(rows[index]) || units.isEmpty || rows[index].section != units[units.count - 1].section {
                units.append(MergeUnit(range: index..<(index + 1), start: rows[index].y, span: 0, section: rows[index].section, key: 0))
            } else {
                units[units.count - 1].range = units[units.count - 1].range.lowerBound..<(index + 1)
            }
        }
        // The drop gap: before a unit, after a section's last unit, or inside a group unit.
        let gapHere = gapY != nil && gap.map { gap in units.contains { $0.section == gap.section } } == true
        var gapBefore: Int?, gapAfterSection: SectionID?, gapInside: Int?
        if gapHere, let gap, let top = gapY {
            if let group = gap.group {
                gapInside = units.firstIndex { rows[$0.range.lowerBound].key == .group(group) }
            } else {
                gapBefore = units.firstIndex { $0.section == gap.section && rows[$0.range.lowerBound].siblingIndex == gap.index && $0.start >= top }
                if gapBefore == nil { gapAfterSection = gap.section }
            }
            // Take the gap out: a unit after it moves back up by its shift.
            for u in units.indices where (gapInside.map { u > $0 } ?? (units[u].start >= top)) {
                units[u].start -= gapShift
                for r in units[u].range { rows[r].y -= gapShift }
            }
            if let gapInside { units[gapInside].holdsGap = true }
        }
        // Heights, keys.
        var previousKey: [SectionID: UInt64] = [:]
        for u in units.indices {
            let first = rows[units[u].range.lowerBound]
            if u + 1 < units.count {
                units[u].span = units[u + 1].start - units[u].start
            } else {
                let last = units[u].range.map { rows[$0].maxY }.max() ?? units[u].start
                var span = last - units[u].start + m.rowSpacing
                if case .group = first.key, !first.isCollapsed { span += m.groupBottomPadding }
                units[u].span = span
            }
            if units[u].holdsGap, u + 1 < units.count { units[u].span += gapShift }
            if case let .workspace(id) = first.key, let time = created[id] {
                units[u].key = time
            } else {
                units[u].key = previousKey[units[u].section] ?? .max
            }
            previousKey[units[u].section] = units[u].key
        }
        // The merge: per section a queue in its own order; at each step the newest head, the first section on a tie.
        var order: [SectionID] = []
        var queues: [SectionID: [Int]] = [:]
        for u in units.indices {
            if queues[units[u].section] == nil { order.append(units[u].section) }
            queues[units[u].section, default: []].append(u)
        }
        var heads = Dictionary(uniqueKeysWithValues: order.map { ($0, 0) })
        var merged: [Int] = []
        merged.reserveCapacity(units.count)
        while merged.count < units.count {
            var best: (section: SectionID, unit: Int)?
            for section in order {
                guard let queue = queues[section], let head = heads[section], head < queue.count else { continue }
                let unit = queue[head]
                if let current = best, units[unit].key <= units[current.unit].key { continue }
                best = (section, unit)
            }
            guard let best else { break }
            merged.append(best.unit)
            heads[best.section, default: 0] += 1
        }
        // Lay the units out again from the run's top, the gap at its place.
        var y = units.map(\.start).min() ?? 0
        var newGapY = gapY
        var placed: [SidebarRow] = []
        placed.reserveCapacity(run.count)
        var remaining = Dictionary(order.map { ($0, queues[$0]?.count ?? 0) }, uniquingKeysWith: { first, _ in first })
        for u in merged {
            if gapBefore == u { newGapY = y; y += gapShift }
            if gapInside == u, let top = gapY { newGapY = top - units[u].start + y }
            let delta = y - units[u].start
            for r in units[u].range {
                var row = rows[r]
                row.y += delta
                placed.append(row)
            }
            y += units[u].span
            remaining[units[u].section, default: 1] -= 1
            if gapAfterSection == units[u].section, remaining[units[u].section] == 0 { newGapY = y; y += gapShift }
        }
        guard placed.count == run.count else { return }
        rows.replaceSubrange(run, with: placed)
        gapY = newGapY
    }
}
