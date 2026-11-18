import AppKit
import CmuxNextDesign

// A top section's fold (Leo 2026-11-08: "there's the sidebar where when things maybe open or shift a bit, there's like
// still a bit of a flicker on that, like individual top group"). A section of the sidebar document draws as one block
// row; its fold changes that row's height only. Before, the fold reloaded the whole list (every row laid out, every
// realized row configured) and the block took its items away in the first frame of a close. Now the list splices the
// block row's new height into the layout it shows and moves only the row views it has, as a group's fold does
// (`foldGroup`): nothing here visits every row, so a fold costs the same with 10,000 workspaces as with 100.
extension SidebarListViewComponents {
    /// Shows `old` -> the list's `blocks` as section fold when that is all that changed: one section folded or opened,
    /// a section that lists no rows of its own (its items all draw in the block). Returns false when the change is
    /// anything else, or a drag, a filter, a held change or the chat history owns the rows: the caller reloads.
    func foldBlock(from old: SidebarListBlocks?) -> Bool {
        guard let old, let new = blocks, model.followsUserIntent, drag == nil, settling == nil, landing == nil, external == nil,
              !isShiftingViewport, !holdsModelChange, displayed.gapY == nil, displayed.pinnedChatsY == nil,
              displayed.earlierChatsY == nil else { return false }
        let toggled = old.collapsed.symmetricDifference(new.collapsed)
        guard toggled.count == 1, let id = toggled.first?.rawValue else { return false }
        var unfolded = new
        unfolded.collapsed = old.collapsed
        guard unfolded == old, model.sections.first(where: { $0.id == .custom(id) })?.nodes.isEmpty == true,
              let position = displayed.position(of: .block(id)), let content = blockContent(id, includeGap: true) else { return false }
        let row = displayed.rows[position]
        let height = SidebarRegionView.layout(of: content, width: bounds.width).height
        // A block that would draw nothing (or drew nothing) leaves the list or joins it: the full layout's rules.
        guard height > 0 else { return false }
        SidebarPerfCounters.add(.blockFolds)
        var resized = row
        resized.height = height
        let dy = height - row.height
        displayed.replaceRows(position..<position + 1, with: [resized], shiftingFollowingBy: dy)
        // The full layout this one stands for, for a later one-row splice (`spliceInsertion`).
        spliceBase?.options.blockHeights[id] = height
        spliceBase?.options.collapsedDocSections = Set(model.collapsedLayoutSections.map(\.rawValue))
        applyBlockFold(row: resized, by: dy)
        return true
    }

    /// Moves the realized rows to the spliced layout: the block springs to its new height (its region clips its items to
    /// it, `SidebarRegionView.beginFoldMove`), the rows below it move by `dy`, and rows the move brings into view get views.
    private func applyBlockFold(row block: SidebarRow, by dy: CGFloat) {
        let previousHoverSuppression = suppressHoverEffects
        suppressHoverEffects = true
        defer {
            suppressHoverEffects = previousHoverSuppression
            updateHover()
        }
        let layout = displayed
        updateDocumentHeight()
        let wasStuck = stuckHeader
        stuckHeader = findStuckHeader(in: layout)
        defer { endStuckPass(from: wasStuck) }
        var targets: [(SidebarRowView, NSRect)] = []
        for (key, view) in rowViews {
            guard let row = layout.row(for: key) else { continue }
            let target = drawnFrame(for: row)
            view.targetSize = target.size
            if key == block.key { configure(view, row: row, animated: true) }
            targets.append((view, target))
        }
        // The rows a close brings up into view start where they were, `dy` lower.
        let realize = realizationRect()
        for index in layout.rowIndices(from: realize.minY, to: realize.maxY) {
            let row = layout.rows[index]
            guard rowViews[row.key] == nil else { continue }
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let view = dequeue(row.key)
            view.targetSize = target.size
            configure(view, row: row, animated: false)
            view.layer?.removeAllAnimations()
            Motion.withoutAnimation {
                view.frame = target.offsetBy(dx: 0, dy: -dy)
                view.alphaValue = 1
            }
            addSubview(view, positioned: .above, relativeTo: decorations)
            rowViews[row.key] = view
            targets.append((view, target))
        }
        // The group lines below the block move with their rows; a group the move brings near the rows gets its line.
        var lines = groupLineViews.lines
        for index in lines.indices where lines[index].frame.minY > block.y {
            lines[index].frame.origin.y += dy
            lines[index].rail?.origin.y += dy
        }
        let listed = Set(lines.map(\.group))
        for line in groupLines(layout) where !listed.contains(line.group) {
            lines.insert(line, at: lines.firstIndex { $0.frame.minY > line.frame.minY } ?? lines.count)
        }
        let lineMotion = groupLineViews.update(lines, from: [], in: self, above: decorations, animated: true)
        RowMotion(targets: targets, appearing: [], leaving: [], lines: lineMotion).run(in: self, from: layout, to: layout, animated: true)
        inlineRename.follow()
    }
}
