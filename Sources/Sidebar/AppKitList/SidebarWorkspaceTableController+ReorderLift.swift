import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import SwiftUI

/// Freeform reorder visuals: the pointer poll, the lifted block and the
/// rows shifting around it, and the settle after a drop. The stored state
/// stays on the controller.
extension SidebarWorkspaceTableController {
    func startReorderPoll(workspaceId: UUID) {
        stopReorderPoll()
        reorderPollWorkspaceId = workspaceId
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reorderPollTick()
            }
        }
        // .common so the timer keeps firing inside the drag's event-tracking
        // loop, which is the only time it exists.
        RunLoop.main.add(timer, forMode: .common)
        reorderPollTimer = timer
    }

    func stopReorderPoll() {
        reorderPollTimer?.invalidate()
        reorderPollTimer = nil
        reorderPollWorkspaceId = nil
    }

    func reorderPollTick() {
        guard let workspaceId = reorderPollWorkspaceId,
              let containerView,
              let window = containerView.tableView.window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let table = containerView.tableView
        let point = table.convert(windowPoint, from: nil)
        // Away from the list, the drag carries its own picture of the row
        // (another window, a pane); back over it, the lift is the picture.
        syncReorderDragGhost(shown: Self.reorderDragShowsGhost(
            tablePointX: point.x,
            tableWidth: table.bounds.width,
            windowFrame: window.frame,
            screenPoint: NSEvent.mouseLocation
        ))
        // Outside the sidebar horizontally (a cross-window or into-terminal
        // excursion): freeze the shift state rather than keep reacting to a
        // pointer that is no longer about this list. The session ends only
        // at endedAt.
        guard Self.reorderPointIsOverList(tablePointX: point.x, tableWidth: table.bounds.width) else { return }
        updateReorderLift(windowPoint: windowPoint, workspaceId: workspaceId)
    }

    /// Frozen drag geometry. Captured once when the drag first hovers, and
    /// never updated until the drag ends: every visual decision during the
    /// drag is made against these frames, so displacement boundaries cannot
    /// move mid-drag and the interaction cannot oscillate. The model is not
    /// touched until release; everything the user sees during the drag is
    /// layer transforms over an unchanged table.
    struct ReorderLiftSession {
        let workspaceId: UUID
        /// Rows travelling with the pointer: one row, or a group header plus
        /// its visible members. A group's header mints its anchor's id (see
        /// `pasteboardWriterForRow`), so an anchor drag is a whole-group move
        /// and the block is what the hand is holding.
        let sourceRange: Range<Int>
        /// Every other row, grouped into the units that shift as one. A row
        /// drag parts single rows (a row can slot inside a group); a group
        /// drag parts whole groups (a group only reorders among top-level
        /// units), so a header never separates from its members mid-drag.
        let otherUnits: [Range<Int>]
        let frames: [CGRect]
        /// Vertical gap between adjacent rows, so re-laid units keep it.
        let rowSpacing: CGFloat
        /// Pointer offset from the top of the dragged block at pickup. Keep
        /// this stable so a multi-row group does not jump to center itself
        /// under the pointer when the lift starts.
        let pointerOffsetY: CGFloat
        /// The applied translation target per row index, so a row only
        /// animates when its target actually flips.
        var appliedTargets: [CGFloat]
        /// The pointer the last update placed the block for (window space),
        /// so a rebuild after a structural update re-places it exactly.
        var lastWindowPoint: NSPoint

        func height(of unit: Range<Int>) -> CGFloat {
            frames[unit].reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, unit.count - 1))
        }
    }

    /// The row range a drag of `workspaceId` carries: a group header plus
    /// its visible members when the id is a group anchor, else the one row.
    func reorderSourceRange(for workspaceId: UUID) -> Range<Int>? {
        guard let first = rows.firstIndex(where: { $0.workspaceId == workspaceId }) else { return nil }
        guard rows[first].isGroupHeader, let groupId = rows[first].groupId else {
            return first..<(first + 1)
        }
        return groupBlockRange(headerIndex: first, groupId: groupId)
    }

    /// Header row plus the contiguous member rows below it. A collapsed
    /// group shows no members, so its block is the header alone.
    func groupBlockRange(headerIndex: Int, groupId: UUID) -> Range<Int> {
        var end = headerIndex + 1
        while end < rows.count, !rows[end].isGroupHeader, rows[end].groupId == groupId {
            end += 1
        }
        return headerIndex..<end
    }

    /// The units that part around a dragged block, in row order.
    func reorderUnits(excluding source: Range<Int>, wholeGroups: Bool) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var index = 0
        while index < rows.count {
            if source.contains(index) {
                index = source.upperBound
                continue
            }
            if wholeGroups, rows[index].isGroupHeader, let groupId = rows[index].groupId {
                let block = groupBlockRange(headerIndex: index, groupId: groupId)
                units.append(block)
                index = block.upperBound
            } else {
                units.append(index..<(index + 1))
                index += 1
            }
        }
        return units
    }

    /// Glides a row's vertical shift to `target` with a soft spring.
    ///
    /// Explicit animation on purpose: view-backing layers on macOS ignore
    /// implicit CATransaction animations (NSView's layer delegate returns
    /// no action), so transform changes here otherwise land instantly no
    /// matter what the transaction says. Starting from the presentation
    /// layer's live value means a retarget mid-glide continues from where
    /// the row visually is instead of jumping.
    /// `from` overrides the presentation read when the row's frame just
    /// changed under it (a lift rebuild), where the presentation layer still
    /// holds an offset from the old frame.
    func glideRowShift(layer: CALayer, to target: CGFloat, from start: CGFloat? = nil) {
        let currentY = start ?? (layer.presentation() ?? layer)
            .value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = currentY
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 300
        spring.damping = 30
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "cmux.reorderShift")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, target, 0)
        CATransaction.commit()
    }

    /// Drives the freeform drag visuals for the pointer at `windowPoint`.
    /// `carry` is set once, right after a structural update rebuilt the rows
    /// under a live drag (see `ReorderLiftCarryOver`).
    func updateReorderLift(windowPoint: NSPoint, workspaceId: UUID, carry: ReorderLiftCarryOver? = nil) {
        guard let containerView else { return }
        let table = containerView.tableView
        let point = table.convert(windowPoint, from: nil)

        if reorderLiftSession?.workspaceId != workspaceId {
            endReorderLift(animated: false)
            // A quick re-grab can land while the last drop is still settling.
            // Finish those glides first: an in-flight animation overrides the
            // transforms the lift sets, so the new drag would lag or snap.
            // Every row also drops back to the base layer (a settle raises it).
            table.enumerateAvailableRowViews { rowView, _ in
                guard let layer = rowView.layer else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if layer.animation(forKey: "cmux.reorderShift") != nil {
                    layer.removeAnimation(forKey: "cmux.reorderShift")
                    layer.transform = CATransform3DIdentity
                }
                layer.zPosition = 0
                CATransaction.commit()
            }
            guard let sourceRange = reorderSourceRange(for: workspaceId) else { return }
            let frames = (0..<rows.count).map { table.rect(ofRow: $0) }
            guard frames.indices.contains(sourceRange.lowerBound),
                  frames[sourceRange.lowerBound].height > 0 else { return }
            let isGroupDrag = rows[sourceRange.lowerBound].isGroupHeader
            reorderLiftSession = ReorderLiftSession(
                workspaceId: workspaceId,
                sourceRange: sourceRange,
                otherUnits: reorderUnits(excluding: sourceRange, wholeGroups: isGroupDrag),
                frames: frames,
                rowSpacing: frames.count > 1 ? max(0, frames[1].minY - frames[0].maxY) : 0,
                pointerOffsetY: carry?.pointerOffsetY ?? (reorderDragStartWorkspaceId == workspaceId
                    ? (reorderDragStartPointerOffsetY ?? point.y - frames[sourceRange.lowerBound].minY)
                    : point.y - frames[sourceRange.lowerBound].minY),
                appliedTargets: Array(repeating: 0, count: rows.count),
                lastWindowPoint: windowPoint
            )
            table.reorderPinnedRowsRect = sourceRange.reduce(CGRect.null) { $0.union(frames[$1]) }
            if carry.map({ reattachReorderLiftSnapshots($0, table: table, sourceRange: sourceRange) }) != true {
                installReorderLiftSnapshots(table: table, sourceRange: sourceRange)
            }
        }
        guard var session = reorderLiftSession else { return }
        session.lastWindowPoint = windowPoint

        // Keep the same pointer-to-block offset captured at pickup. Centering
        // a multi-row block under the pointer makes a group jump by roughly
        // half its height as soon as the lift begins. Clamp the block top so
        // it stays within the list while preserving that offset everywhere
        // else.
        let blockTop = session.frames[session.sourceRange.lowerBound].minY
        let blockFrame = session.sourceRange.reduce(CGRect.null) { $0.union(session.frames[$1]) }
        table.reorderPinnedRowsRect = blockFrame
        let placement = reorderLiftPlacement(session, pointY: point.y, tableMaxY: table.bounds.maxY)
        let draggedTop = placement.draggedTop
        let blockShift = draggedTop - blockTop

        // Insertion slot from frozen midpoints: how many other units sit
        // above the block's slot probe (see `reorderLiftPlacement`).
        let insertion = session.otherUnits.filter { unit in
            let top = session.frames[unit.lowerBound].minY
            return top + session.height(of: unit) / 2 < placement.slotProbeY
        }.count

        // Re-lay every unit in drop order and read each row's offset from
        // where it would land. Exact for mixed heights (a header is not a
        // row) and for blocks, where a plain one-row-height shift is wrong.
        var order = session.otherUnits
        order.insert(session.sourceRange, at: insertion)
        var targets = Array(repeating: CGFloat(0), count: session.frames.count)
        var nextTop = session.frames[0].minY
        for unit in order {
            if unit != session.sourceRange {
                let delta = nextTop - session.frames[unit.lowerBound].minY
                for row in unit { targets[row] = delta }
            }
            nextTop += session.height(of: unit) + session.rowSpacing
        }

        table.enumerateAvailableRowViews { rowView, row in
            guard session.frames.indices.contains(row) else { return }
            rowView.wantsLayer = true
            guard let layer = rowView.layer else { return }
            if session.sourceRange.contains(row) {
                // Pointer-driven, never animated: any smoothing here reads
                // as the block lagging the hand.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.zPosition = 100
                layer.transform = CATransform3DMakeTranslation(0, blockShift, 0)
                CATransaction.commit()
                return
            }
            let target = targets[row]
            if let carry {
                // First pass after a rebuild: every row continues from where
                // it stood on screen before the update, never from zero.
                session.appliedTargets[row] = target
                layer.zPosition = 0
                continueRebuiltRowShift(layer: layer, row: row, target: target, frameTop: session.frames[row].minY, carry: carry)
            } else if session.appliedTargets[row] != target {
                session.appliedTargets[row] = target
                layer.zPosition = 0
                glideRowShift(layer: layer, to: target)
            } else if layer.animation(forKey: "cmux.reorderShift") == nil {
                // Reused row views arrive with whatever transform their
                // previous tenant had; keep visible rows pinned to their
                // current target every tick (but never stamp over a glide
                // that is still in flight).
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DMakeTranslation(0, target, 0)
                CATransaction.commit()
            }
        }
        reorderLiftSession = session
    }

    /// Glides the just-dropped block from where it stood under the pointer
    /// into its committed slot. The other rows already stand at their new
    /// places (the lift showed them there), so only the block moves.
    func settleReorderedBlock(ids: [SidebarWorkspaceRenderItemID], fromVisualTop visualTop: CGFloat) {
        guard let table = containerView?.tableView,
              let firstId = ids.first,
              let firstIndex = rows.firstIndex(where: { $0.id == firstId }) else { return }
        let delta = visualTop - table.rect(ofRow: firstIndex).minY
        guard abs(delta) > 0.5 else { return }
        let idSet = Set(ids)
        for (index, row) in rows.enumerated() where idSet.contains(row.id) {
            guard let layer = table.rowView(atRow: index, makeIfNecessary: false)?.layer else { continue }
            // Explicit start: the presentation layer still holds the lift's
            // old offset (relative to the row's old frame) until the next
            // frame, so reading it, as `glideRowShift` does, would start the
            // glide from the wrong place and the block would jump first.
            // A plain ease-out, not a spring: the block can land up to a row
            // away from its slot, and a spring's fast start and long tail
            // read as a snap over that distance. Longer travel, longer glide.
            let settle = CABasicAnimation(keyPath: "transform.translation.y")
            settle.fromValue = delta
            settle.toValue = 0
            settle.duration = min(0.3, 0.18 + abs(delta) / 700)
            settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Back to the base layer once the glide ends, unless a new lift
            // owns the row by then.
            CATransaction.setCompletionBlock { [weak self, weak layer] in
                MainActor.assumeIsolated {
                    guard let self, let layer, self.reorderLiftSession == nil else { return }
                    layer.zPosition = 0
                    // The block has landed under a still pointer.
                    self.rederiveHoverAfterDrag()
                }
            }
            layer.removeAnimation(forKey: "cmux.reorderShift")
            layer.transform = CATransform3DIdentity
            layer.zPosition = 100
            layer.add(settle, forKey: "cmux.reorderShift")
            CATransaction.commit()
        }
    }

    func installReorderLiftSnapshots(table: NSTableView, sourceRange: Range<Int>) {
        removeReorderLiftSnapshots()
        suspendHoverForDrag()
        // Hover just left the lifted rows (close button back to its badge);
        // lay them out before they are snapshotted.
        for row in sourceRange { table.rowView(atRow: row, makeIfNecessary: false)?.layoutSubtreeIfNeeded() }
        let scale = table.window?.backingScaleFactor ?? 2
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        for row in sourceRange {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false),
                  let rowLayer = rowView.layer else { continue }
            // Optionally, a lifted group header wears its active (selected)
            // look for the whole drag. Off by default, behind the
            // `sidebarDragHeaderActiveLook` defaults key while it is tuned.
            if UserDefaults.standard.bool(forKey: "sidebarDragHeaderActiveLook"),
               let header = rowView.view(atColumn: 0) as? SidebarGroupHeaderTableCellView {
                header.showOptimisticAnchorActive()
                header.displayIfNeeded()
            }
            let size = rowLayer.bounds.size
            guard size.width > 0, size.height > 0,
                  let context = CGContext(
                      data: nil,
                      width: Int((size.width * scale).rounded(.up)),
                      height: Int((size.height * scale).rounded(.up)),
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { continue }
            context.scaleBy(x: scale, y: scale)
            // A single workspace row: lift its fill out as its own layer and
            // snapshot the content without it (see `reorderLiftIndent`).
            let workspaceCell = sourceRange.count == 1
                ? rowView.view(atColumn: 0) as? SidebarWorkspaceRowTableCellView
                : nil
            let fill = workspaceCell?.makeLiftFillLayer(in: rowView)
            if let workspaceCell {
                workspaceCell.setLiftFillHidden(true)
                workspaceCell.displayIfNeeded()
            }
            if rowView.isFlipped {
                // Row views are flipped; render upright into the bitmap.
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            rowLayer.render(in: context)
            workspaceCell?.setLiftFillHidden(false)
            guard let image = context.makeImage() else { continue }
            let snapshot = CALayer()
            snapshot.frame = rowLayer.bounds
            snapshot.zPosition = 1000
            let content = CALayer()
            content.contents = image
            content.contentsScale = scale
            content.contentsGravity = .resize
            content.frame = snapshot.bounds
            if let fill { snapshot.addSublayer(fill) }
            snapshot.addSublayer(content)
            if workspaceCell != nil {
                let wasGrouped = rows.indices.contains(row) && rows[row].groupId != nil
                reorderLiftIndent = (fill, content, fill?.frame ?? .zero, wasGrouped, wasGrouped)
            }
            let cell = rowView.view(atColumn: 0) as? NSView
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rowLayer.addSublayer(snapshot)
            cell?.isHidden = true
            CATransaction.commit()
            reorderLiftSnapshots.append((rowView, cell, snapshot))
        }
    }

    /// Moves the lifted row's indent to match where it would land.
    func updateReorderLiftIndent(isGrouped: Bool) {
        guard var lift = reorderLiftIndent, lift.isGrouped != isGrouped else { return }
        lift.isGrouped = isGrouped
        reorderLiftIndent = lift
        let indent = SidebarWorkspaceGroupingMetrics.memberIndent
        let shift = (isGrouped ? indent : 0) - (lift.wasGrouped ? indent : 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.25, 1))
        lift.content.transform = CATransform3DMakeTranslation(shift, 0, 0)
        if let fill = lift.fill {
            // The right edge stays put; only the leading edge follows.
            var frame = lift.fillFrame
            frame.origin.x += shift
            frame.size.width -= shift
            fill.frame = frame
        }
        CATransaction.commit()
    }

    func removeReorderLiftSnapshots() {
        reorderLiftIndent = nil
        guard !reorderLiftSnapshots.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in reorderLiftSnapshots {
            entry.layer.removeFromSuperlayer()
            entry.cell?.isHidden = false
            // Drop the lift-only active look; the stored model decides again.
            (entry.cell as? SidebarGroupHeaderTableCellView)?.restoreStoredModelPaint()
        }
        CATransaction.commit()
        reorderLiftSnapshots.removeAll()
    }

    /// Where the lifted block sits for a pointer at `pointY` (table space),
    /// and the y that decides its slot. The probe is the block's leading edge
    /// in the direction it moved, not its centre: the block is clamped to the
    /// list, so a block taller than the rows below it could never carry its
    /// centre past their midpoints and the last slots were unreachable. The
    /// drop planner is fed the same probe, so the commit matches the preview.
    func reorderLiftPlacement(
        _ session: ReorderLiftSession,
        pointY: CGFloat,
        tableMaxY: CGFloat
    ) -> (draggedTop: CGFloat, slotProbeY: CGFloat) {
        let blockHeight = session.height(of: session.sourceRange)
        let blockTop = session.frames[session.sourceRange.lowerBound].minY
        let minTop = session.frames[0].minY
        let maxTop = max(minTop, tableMaxY - blockHeight)
        let draggedTop = min(max(pointY - session.pointerOffsetY, minTop), maxTop)
        let slotProbeY: CGFloat
        if draggedTop > blockTop + 0.5 {
            slotProbeY = draggedTop + blockHeight - 1
        } else if draggedTop < blockTop - 0.5 {
            slotProbeY = draggedTop + 1
        } else {
            slotProbeY = draggedTop + blockHeight / 2
        }
        return (draggedTop, slotProbeY)
    }

    /// Ends the visual session. Animated: rows glide back to their real
    /// frames (a cancelled drag). Not animated: transforms drop instantly
    /// (the structural apply is about to redraw the true order).
    func endReorderLift(animated: Bool) {
        guard reorderLiftSession != nil else { return }
        reorderLiftSession = nil
        removeReorderLiftSnapshots()
        guard let containerView else { return }
        let table = containerView.tableView
        table.reorderPinnedRowsRect = nil
        table.enumerateAvailableRowViews { [self] rowView, _ in
            guard let layer = rowView.layer else { return }
            if animated {
                glideRowShift(layer: layer, to: 0)
            } else {
                layer.removeAnimation(forKey: "cmux.reorderShift")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            layer.zPosition = 0
        }
    }
}
