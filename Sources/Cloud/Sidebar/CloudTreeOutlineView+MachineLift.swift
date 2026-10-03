import AppKit

/// Coordinator side of the continuous machine drag (`CloudTreeMachineReorderLift`).
extension CloudTreeOutlineView.Coordinator {
    /// Removes the fallback monitor used when AppKit omits a drag-end callback.
    func removeMachineLiftMouseUpMonitor() {
        if let monitor = machineLiftMouseUpMonitor { NSEvent.removeMonitor(monitor) }
        machineLiftMouseUpMonitor = nil
    }

    /// Finishes the native drag through the same coordinator path as `endedAt`.
    func installMachineLiftMouseUpMonitor(for session: NSDraggingSession, in outline: CloudTreeNSOutlineView) {
        removeMachineLiftMouseUpMonitor()
        machineLiftMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      self.activeDragSession === session,
                      self.activeDragSequenceNumber == session.draggingSequenceNumber else { return }
                self.outlineView(outline, draggingSession: session, endedAt: event.locationInWindow, operation: [])
            }
            return event
        }
    }

    /// Starts the lift when the drag that just began carries a machine row.
    func liftMachineDrag(_ session: NSDraggingSession, draggedItems: [Any], in outlineView: NSOutlineView) {
        guard machineLiftEnabled, let node = draggedItems.first as? CloudTreeNode, node.canReorderMachine,
              let outline = outlineView as? CloudTreeNSOutlineView else { return }
        hideDragImage(of: session, in: outline)
        beginMachineLift(session, node: node, in: outline)
    }

    /// Lifts a machine row for the drag that just began. Open machines close
    /// for the drag without recording it, so the person's expansion is what
    /// comes back afterwards.
    func beginMachineLift(
        _ session: NSDraggingSession, node: CloudTreeNode, in outline: CloudTreeNSOutlineView, pressY: CGFloat? = nil
    ) {
        guard node.canReorderMachine,
              let scope = CloudMachineReorderScope(machineNodeID: node.id, roots: nodes) else { return }
        outline.machineLift.begin(
            sequence: session.draggingSequenceNumber, source: node, siblings: scope.siblings, pressY: pressY
        ) { machines in
            withProgrammaticUpdate {
                for machine in machines { outline.collapseItem(machine) }
            }
        }
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
        return outline.machineLift.finish(reopen: { [weak self] ids in
            guard let self else { return }
            let visibleNodes = outline.visibleItemsByID()
            withProgrammaticUpdate {
                for id in ids {
                    if let machine = visibleNodes[id], !outline.isItemExpanded(machine) {
                        outline.expandItem(machine)
                    }
                }
                self.restoreSelection(in: outline)
            }
        }, mutate: commit)
    }
}
