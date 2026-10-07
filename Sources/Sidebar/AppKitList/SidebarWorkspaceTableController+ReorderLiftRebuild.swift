import AppKit

/// Keeping a live drag's lift through a structural update (a workspace
/// created or closed mid-drag). The update moves rows and can swap row
/// views, so the frozen frames, the source range, the pinned rect and the
/// snapshots all go stale. Ending the lift and letting the next poll tick
/// start over dropped every row to its real frame for a frame and glided it
/// out again: one visible bounce. Instead the lift is carried over and
/// rebuilt against the new rows in the same update.
extension SidebarWorkspaceTableController {
    /// What survives from the old lift into the rebuilt one.
    struct ReorderLiftCarryOver {
        let workspaceId: UUID
        let pointerOffsetY: CGFloat
        let windowPoint: NSPoint
        /// Snapshot layers of the lifted rows, in row order, detached from
        /// their old row views. Moved as is, so the block keeps the exact
        /// picture (and live indent) it had.
        let snapshotLayers: [CALayer]
        let indent: (
            fill: CALayer?, content: CALayer, fillFrame: CGRect, wasGrouped: Bool, isGrouped: Bool
        )?
        /// Where each loaded row stood on screen (table space, transform
        /// included) before the update.
        let visualTops: [SidebarWorkspaceRenderItemID: CGFloat]
    }

    /// Detaches the live lift before a structural update touches the table.
    /// Call while `previousRows` still describes the table's rows. Returns
    /// nil when no drag is live (no session, or a drop is handing its
    /// transforms to this very apply).
    func detachReorderLiftForRebuild(
        previousRows: [SidebarWorkspaceTableRowConfiguration],
        isDropHandOff: Bool
    ) -> ReorderLiftCarryOver? {
        guard !isDropHandOff, let session = reorderLiftSession,
              let table = containerView?.tableView else { return nil }
        var visualTops: [SidebarWorkspaceRenderItemID: CGFloat] = [:]
        table.enumerateAvailableRowViews { rowView, row in
            guard previousRows.indices.contains(row) else { return }
            let layer = rowView.layer
            // Mid-glide the presentation is what is on screen; at rest the
            // model is, and a presentation copy can lag it until the next
            // commit (a just-removed glide still reads mid-flight).
            let isGliding = !(layer?.animationKeys() ?? []).isEmpty
            let shift = ((isGliding ? layer?.presentation() : nil) ?? layer)?
                .value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
            visualTops[previousRows[row].id] = rowView.frame.minY + shift
        }
        let carry = ReorderLiftCarryOver(
            workspaceId: session.workspaceId,
            pointerOffsetY: session.pointerOffsetY,
            windowPoint: session.lastWindowPoint,
            snapshotLayers: reorderLiftSnapshots.map(\.layer),
            indent: reorderLiftIndent,
            visualTops: visualTops
        )
        // Give the old row views their cells back; the layers travel on.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in reorderLiftSnapshots {
            entry.layer.removeFromSuperlayer()
            entry.cell?.isHidden = false
            (entry.cell as? SidebarGroupHeaderTableCellView)?.restoreStoredModelPaint()
        }
        CATransaction.commit()
        reorderLiftSnapshots.removeAll()
        reorderLiftIndent = nil
        return carry
    }

    /// Re-lifts the dragged block against the updated rows. The dragged
    /// workspace may be gone (closed mid-drag); then the lift simply ends.
    func rebuildReorderLift(from carry: ReorderLiftCarryOver) {
        endReorderLift(animated: false)
        updateReorderLift(windowPoint: carry.windowPoint, workspaceId: carry.workspaceId, carry: carry)
    }

    /// Moves the carried snapshot layers onto the rows' current row views.
    /// False when the block's row count changed (a member joined or left
    /// the dragged group), so the caller takes fresh snapshots instead.
    func reattachReorderLiftSnapshots(
        _ carry: ReorderLiftCarryOver,
        table: NSTableView,
        sourceRange: Range<Int>
    ) -> Bool {
        removeReorderLiftSnapshots()
        guard !carry.snapshotLayers.isEmpty, carry.snapshotLayers.count == sourceRange.count else { return false }
        let rowViews = sourceRange.compactMap { table.rowView(atRow: $0, makeIfNecessary: true) }
        guard rowViews.count == sourceRange.count, rowViews.allSatisfy({ $0.layer != nil }) else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (rowView, snapshot) in zip(rowViews, carry.snapshotLayers) {
            guard let rowLayer = rowView.layer else { continue }
            let cell = rowView.view(atColumn: 0) as? NSView
            snapshot.frame = rowLayer.bounds
            rowLayer.addSublayer(snapshot)
            cell?.isHidden = true
            reorderLiftSnapshots.append((rowView, cell, snapshot))
        }
        CATransaction.commit()
        reorderLiftIndent = carry.indent
        return true
    }

    /// The rebuild pass for one displaced row: glide on from where it stood
    /// before the update, or land in place when it barely moved (or did not
    /// exist yet, like the row just created).
    func continueRebuiltRowShift(
        layer: CALayer,
        row: Int,
        target: CGFloat,
        frameTop: CGFloat,
        carry: ReorderLiftCarryOver
    ) {
        if rows.indices.contains(row),
           let oldTop = carry.visualTops[rows[row].id],
           abs(oldTop - frameTop - target) > 0.5 {
            glideRowShift(layer: layer, to: target, from: oldTop - frameTop)
            return
        }
        layer.removeAnimation(forKey: "cmux.reorderShift")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, target, 0)
        CATransaction.commit()
    }
}
