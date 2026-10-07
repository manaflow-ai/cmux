import AppKit
import CmuxNextWakeups
import CmuxNextDesign
import QuartzCore
// Internal drag reorder: lift, in-place slot (R77), drop, cancel, auto-scroll.
extension SidebarListView {
    typealias Drag = SidebarListDrag
    func beginDrag(_ press: Press) {
        hoverCards.dismiss(.click)
        guard let row = displayed.row(for: press.key) else { return }
        let payload: DragPayload
        var hidden: Set<SidebarRowKey>
        let origin: DropTarget?
        switch press.key {
        case let .workspace(id):
            guard !model.isPlaceholder(id) else { return }
            let ids = model.selection.contains(id) ? model.orderedSelection : [id]
            if !model.selection.contains(id) { model.click(id) }
            payload = .workspaces(ids)
            hidden = Set(ids.map(SidebarRowKey.workspace))
            origin = ids.first.flatMap { SidebarEdits.position(of: $0, in: model.sections) }.map(DropTarget.position)
        case let .group(group):
            guard let (s, n) = SidebarEdits.locateGroup(group, in: model.sections) else { return }
            payload = .group(group)
            hidden = [.group(group)]
            for ws in groups[group]?.workspaces ?? [] { hidden.insert(.workspace(ws.id)) }
            origin = .position(DropPosition(section: model.sections[s].id, index: n))
        case .tab, .section, .emptySection:
            return
        }
        hidden.formUnion(Self.tabKeys(of: hidden, in: model))
        let rowFrame = frame(for: row)
        let count: Int
        if case let .workspaces(ids) = payload { count = ids.count } else { count = 1 }
        let content = dequeue(press.key)
        configure(content, row: row, animated: false)
        content.isHovered = false
        content.isSelected = false // The lifted card is its own raised surface: no selection fill on it.
        (content as? WorkspaceRowView)?.isSecondarySelected = false
        let lift = SidebarReorderLift.lift(content, count: count, frame: rowFrame, in: self)
        let drag = Drag(
            payload: payload,
            grabbedKey: press.key,
            hiddenKeys: hidden,
            grabOffsetY: press.point.y - rowFrame.minY,
            gapHeight: row.height,
            lift: lift,
            target: origin
        )
        drag.grabOffsetX = press.point.x - rowFrame.minX
        drag.lastY = press.point.y
        self.drag = drag
        suppressed.formUnion(hidden)
        setHovered(nil)
        for key in hidden { rowViews[key]?.alphaValue = 0 }
        reload(animated: true)
    }
    func updateDrag(windowPoint: NSPoint) {
        guard let drag else { return }
        if SidebarListPinDrop.holds(self, drag, at: windowPoint) { return }
        if offerHandoff(drag, windowPoint: windowPoint) { return }
        drag.lastWindowPoint = windowPoint
        let point = convert(windowPoint, from: nil)
        // The lifted row follows the pointer vertically; x stays locked.
        SidebarReorderLift.follow(drag.lift, top: point.y - drag.grabOffsetY, visible: visibleRect)
        autoscroll.update(windowPoint: windowPoint)
        let card = drag.lift.frame
        if point.y != drag.lastY {
            drag.movingUp = point.y < drag.lastY
            drag.lastY = point.y
        }
        let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
        let resolved = drag.resolve(card: card, displayed: displayed, base: base, sections: model.sections, ungroupedFirst: model.ungroupedFirst)
        guard let target = SidebarGroupDrop.gate(self, drag, card: card, resolved: resolved) else { return }
        guard target != drag.target else { return }
        drag.target = target
        drag.lift.setRefused(target == nil)
        reload(animated: true)
    }
    func finishDrag() {
        guard let drag else { return }
        autoscroll.stop()
        if SidebarListPinDrop.finish(self, drag) { return }
        guard let target = drag.target else { return cancelDrag() }
        self.drag = nil
        switch (drag.payload, target) {
        case let (.workspaces(ids), .position(position)):
            model.send(.reorder(ids, to: position))
        case let (.workspaces(ids), .intoGroup(group)):
            SidebarGroupDrop.join(self, ids, group, origin: drag.origin)
        case let (.group(group), .position(position)):
            model.send(.reorderGroup(group, index: position.index))
        case let (.workspaces(ids), .ontoWorkspace(anchor)):
            SidebarGroupDrop.group(self, ids, onto: anchor, origin: drag.origin) // The target first, then the dragged rows (Arc/Dia).
            drag.renameOnLand = anchor
        case (.group, .intoGroup), (.group, .ontoWorkspace):
            break
        }
        suppressed = drag.hiddenKeys // Rows land under the lifted view, stay hidden until it arrives.
        reload(animated: true)
        land(drag)
    }
    func cancelDrag() {
        guard let drag else { return }
        autoscroll.stop()
        SidebarListPinDrop.end(self)
        self.drag = nil
        press?.cancelled = true
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }
    /// Flies the lifted view to its row's current frame, then swaps it out.
    func land(_ drag: Drag) {
        let destination = displayed.row(for: drag.grabbedKey).map(frame(for:)) ?? drag.lift.frame
        SidebarReorderLift.land(drag.lift, at: destination) { [weak self] in
            guard let self else { return }
            self.suppressed.subtract(drag.hiddenKeys)
            for key in drag.hiddenKeys { self.rowViews[key]?.alphaValue = 1 }
            self.updateHover()
            if let anchor = drag.renameOnLand { self.inlineRename.beginGroup(of: anchor) }
        }
    }
}
