import AppKit

/// Coordinator side of the continuous machine and workspace drag
/// (`CloudTreeMachineReorderLift`).
extension CloudTreeOutlineView.Coordinator {
    /// Starts the lift when the drag that just began carries a machine row
    /// or a row that reorders among its siblings (a workspace).
    func liftMachineDrag(_ session: NSDraggingSession, draggedItems: [Any], in outlineView: NSOutlineView) {
        guard machineLiftEnabled, let node = draggedItems.first as? CloudTreeNode,
              let outline = outlineView as? CloudTreeNSOutlineView else { return }
        if node.canReorderMachine {
            hideDragImage(of: session, in: outline)
            beginMachineLift(session, node: node, in: outline)
        } else if node.canOrganize {
            beginOrganizationLift(session, node: node, in: outline)
        }
    }

    /// Lifts a workspace (or another organizable row) among the siblings in
    /// its pin tier, the same way a machine lifts. These rows can also be
    /// dropped on a pane, so leaving the tree puts the rows back and hands
    /// the drag its native image again.
    private func beginOrganizationLift(_ session: NSDraggingSession, node: CloudTreeNode, in outline: CloudTreeNSOutlineView) {
        guard let parent = CloudSidebarOrganizationTree(nodes: nodes).parent(of: node.id) else {
#if DEBUG
            cmuxDebugLog("cloud.lift.organization skip=noParent node=\(node.id)")
#endif
            return
        }
        let state = organization.state
        let group = parent.organizationGroupID
        let pinned = state.isPinned(node.id, parent: group)
        let isPeer = { (sibling: CloudTreeNode) in
            sibling.canOrganize && state.isPinned(sibling.id, parent: group) == pinned
        }
        // Without a picture to hand back, a drag onto a pane would be invisible.
        guard let image = dragImage(of: node, in: outline) else {
#if DEBUG
            cmuxDebugLog("cloud.lift.organization skip=noSnapshot node=\(node.id)")
#endif
            return
        }
        let lifted = outline.machineLift.begin(
            sequence: session.draggingSequenceNumber, source: node, siblings: parent.children,
            isPeer: isPeer,
            onLeave: { [weak self, weak outline] in
                guard let self, let outline else { return }
                finishMachineLift()
                restoreDragImage(image, of: session, in: outline)
            },
            collapse: { rows in
            withProgrammaticUpdate {
                for row in rows { outline.collapseItem(row) }
            }
            }
        )
#if DEBUG
        cmuxDebugLog("cloud.lift.organization lifted=\(lifted) node=\(node.id) siblings=\(parent.children.count)")
#endif
        guard lifted else { return }
        hideDragImage(of: session, in: outline)
        installMachineLiftMouseUpMonitor(for: session, in: outline)
    }

    /// Lifts a machine row for the drag that just began. Open machines move
    /// with their rows so the person's expansion remains unchanged.
    func beginMachineLift(
        _ session: NSDraggingSession, node: CloudTreeNode, in outline: CloudTreeNSOutlineView, pressY: CGFloat? = nil
    ) {
        guard node.canReorderMachine,
              let scope = CloudMachineReorderScope(machineNodeID: node.id, roots: nodes) else { return }
        outline.machineLift.begin(
            sequence: session.draggingSequenceNumber, source: node, siblings: scope.siblings, pressY: pressY,
            isPeer: { $0.canReorderMachine && $0.isPinned == node.isPinned },
            collapse: { machines in
            self.withProgrammaticUpdate {
                for machine in machines { outline.collapseItem(machine) }
            }
            }
        )
        installMachineLiftMouseUpMonitor(for: session, in: outline)
    }

    /// The real row is the drag visual, so the native image is blank and
    /// never flies back on a cancel.
    func hideDragImage(of session: NSDraggingSession, in outline: NSOutlineView) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.enumerateDraggingItems(
            options: [], for: outline, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, _ in
            let size = item.draggingFrame.size
            item.setDraggingFrame(item.draggingFrame, contents: NSImage(size: size, flipped: false) { _ in true })
        }
    }

    /// A picture of the dragged row, taken before the lift styles it.
    private func dragImage(of node: CloudTreeNode, in outline: NSOutlineView) -> NSImage? {
        let row = outline.row(forItem: node)
        guard row >= 0, let rowView = outline.rowView(atRow: row, makeIfNecessary: false),
              let bitmap = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return nil }
        rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
        let image = NSImage(size: rowView.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Gives a drag that left the tree its image back, so it reads as a
    /// normal drag over the panes.
    private func restoreDragImage(_ image: NSImage, of session: NSDraggingSession, in outline: NSOutlineView) {
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.enumerateDraggingItems(
            options: [], for: outline, classes: [NSPasteboardItem.self], searchOptions: [:]
        ) { item, _, stop in
            stop.pointee = true
            item.setDraggingFrame(item.draggingFrame, contents: image)
        }
    }

    /// The slot the lifted row shows for this drag, after following the
    /// pointer to `info`'s location; nil when no lift owns the drag.
    func machineLiftSlot(_ outlineView: NSOutlineView, info: any NSDraggingInfo) -> Int? {
        guard let outline = outlineView as? CloudTreeNSOutlineView,
              outline.machineLift.isActive(sequence: info.draggingSequenceNumber) else { return nil }
        return outline.machineLift.update(pointerY: outline.convert(info.draggingLocation, from: nil).y)
    }

    func isMachineLiftActive(_ outlineView: NSOutlineView, info: any NSDraggingInfo) -> Bool {
        (outlineView as? CloudTreeNSOutlineView)?.machineLift.isActive(sequence: info.draggingSequenceNumber) == true
    }

    /// Ends the lift: `commit` lands a drop, nil cancels (Escape, a release
    /// outside the tree, a refused slot, or a press after a drag whose end
    /// was never reported). Returns the commit's result.
    @discardableResult
    func finishMachineLift(commit: (() -> Bool)? = nil) -> Bool {
        guard let outline = outlineView else { return false }
        return outline.machineLift.finish(reopen: { _ in }, mutate: { [weak self] in
            guard let self else { return commit?() ?? false }
            let result = commit?() ?? false
            self.restoreSelection(in: outline)
            return result
        })
    }
}
