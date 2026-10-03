import AppKit
import CmuxNextWakeups
import CmuxNextDesign
import QuartzCore

// Internal drag reorder: lift, live gap, drop, cancel, auto-scroll.

extension SidebarListView {
    // MARK: - Drag

    final class Drag {
        let payload: DragPayload
        let grabbedKey: SidebarRowKey
        /// Keys hidden while dragging (the lifted rows).
        let hiddenKeys: Set<SidebarRowKey>
        let grabOffsetY: CGFloat
        /// Press x from the row's leading edge; with `grabOffsetY`, the
        /// point a window-drag hand-off keeps under the pointer.
        var grabOffsetX: CGFloat = 0
        let gapHeight: CGFloat
        let lift: DragLiftView
        var target: DropTarget?
        var lastWindowPoint: NSPoint = .zero

        init(payload: DragPayload, grabbedKey: SidebarRowKey, hiddenKeys: Set<SidebarRowKey>, grabOffsetY: CGFloat, gapHeight: CGFloat, lift: DragLiftView, target: DropTarget?) {
            self.payload = payload
            self.grabbedKey = grabbedKey
            self.hiddenKeys = hiddenKeys
            self.grabOffsetY = grabOffsetY
            self.gapHeight = gapHeight
            self.lift = lift
            self.target = target
        }

        @MainActor func isValid(in model: SidebarModel) -> Bool {
            switch payload {
            case let .workspaces(ids): ids.allSatisfy { model.workspace($0) != nil }
            case let .group(group): model.group(group) != nil
            }
        }
    }

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
        case .section, .emptySection:
            return
        }

        let rowFrame = frame(for: row)
        let count: Int
        if case let .workspaces(ids) = payload { count = ids.count } else { count = 1 }
        let content = dequeue(press.key)
        configure(content, row: row, animated: false)
        content.isHovered = false
        (content as? WorkspaceRowView)?.isSecondarySelected = false
        let lift = DragLiftView(content: content, count: count)
        lift.frame = rowFrame
        addSubview(lift)

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
        self.drag = drag
        suppressed.formUnion(hidden)
        setHovered(nil)
        for key in hidden { rowViews[key]?.alphaValue = 0 }
        reload(animated: true)
        lift.setLifted(true, animated: true)
    }

    func updateDrag(windowPoint: NSPoint) {
        guard let drag else { return }
        if offerHandoff(drag, windowPoint: windowPoint) { return }
        drag.lastWindowPoint = windowPoint
        let point = convert(windowPoint, from: nil)

        // The lifted row follows the pointer vertically; x stays locked.
        var liftFrame = drag.lift.frame
        let visible = visibleRect
        liftFrame.origin.y = min(max(point.y - drag.grabOffsetY, visible.minY - liftFrame.height / 2), visible.maxY - liftFrame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.lift.frame = liftFrame
        CATransaction.commit()
        autoscroll.update(windowPoint: windowPoint)

        guard let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) else { return }
        let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
        let target = DropResolver.resolve(y: baseY, payload: drag.payload, base: base, sections: model.sections,
                                          ungroupedFirst: model.ungroupedFirst)
        guard target != drag.target else { return }
        drag.target = target
        drag.lift.setRefused(target == nil)
        reload(animated: true)
    }

    func finishDrag() {
        guard let drag else { return }
        autoscroll.stop()
        guard let target = drag.target else { return cancelDrag() }
        self.drag = nil
        switch (drag.payload, target) {
        case let (.workspaces(ids), .position(position)):
            model.send(.reorder(ids, to: position))
        case let (.workspaces(ids), .intoGroup(group)):
            model.send(.move(ids, toGroup: group))
        case let (.group(group), .position(position)):
            model.send(.reorderGroup(group, index: position.index))
        case (.group, .intoGroup):
            break
        }
        // Rows land under the lifted view, stay hidden until it arrives.
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }

    func cancelDrag() {
        guard let drag else { return }
        autoscroll.stop()
        self.drag = nil
        press?.cancelled = true
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }

    /// Flies the lifted view to its row's current frame, then swaps it out.
    func land(_ drag: Drag) {
        let destination = displayed.row(for: drag.grabbedKey).map(frame(for:)) ?? drag.lift.frame
        drag.lift.setLifted(false, animated: true)
        Motion.animate(.settle, {
            drag.lift.animator().frame = destination
        }, completion: { [weak self] in
            drag.lift.removeFromSuperview()
            guard let self else { return }
            self.suppressed.subtract(drag.hiddenKeys)
            for key in drag.hiddenKeys { self.rowViews[key]?.alphaValue = 1 }
            self.decorations.setPill(self.activePillFrame(in: self.displayed), animated: false)
            self.updateHover()
        })
    }
}
