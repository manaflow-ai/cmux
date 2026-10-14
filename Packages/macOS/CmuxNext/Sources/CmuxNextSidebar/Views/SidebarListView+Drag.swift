import AppKit
import CmuxNextWakeups
import CmuxNextDesign
import QuartzCore
// Internal drag reorder: lift, in-place slot (R77), drop, cancel, auto-scroll.
extension SidebarListView {
    typealias Drag = SidebarListDrag
    func beginDrag(_ press: Press) {
        hoverCards.dismiss(.click)
        settling = nil
        guard displayed.row(for: press.key) != nil else { return }
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
        case let .item(item):
            // A listed document item drags only on the document.
            guard model.docDrag != nil, let row = displayed.row(for: press.key) else { return }
            payload = .item(item)
            hidden = [press.key]
            origin = .position(DropPosition(section: row.section, index: row.siblingIndex))
        case .tab, .section, .emptySection, .folder, .block:
            return
        }
        hidden.formUnion(Self.tabKeys(of: hidden, in: model))
        // A group lifts as one block: its header and the member rows under it (cx-bp40).
        let rows = SidebarListLift.rows(self, for: press.key, hidden: hidden)
        guard let rowFrame = SidebarListLift.blockFrame(self, rows), let content = SidebarListLift.content(self, rows, in: rowFrame) else { return }
        let count: Int
        if case let .workspaces(ids) = payload { count = ids.count } else { count = 1 }
        let lift = SidebarReorderLift.lift(content, count: count, frame: rowFrame, in: self)
        let drag = Drag(
            payload: payload,
            grabbedKey: press.key,
            hiddenKeys: hidden,
            grabOffsetY: press.point.y - rowFrame.minY,
            gapHeight: rowFrame.height,
            lift: lift, head: rows.first?.height,
            target: origin
        )
        drag.grabOffsetX = press.point.x - rowFrame.minX
        drag.lastY = press.point.y
        drag.restFrame = rowFrame
        if rows.first?.group != nil { // the gutter comes back only for a drop into a group (morphLift)
            drag.restFrame.origin.x -= SidebarStyle.groupGutter
            drag.restFrame.size.width += SidebarStyle.groupGutter
        }
        drag.morphs = rows.count == 1
        self.drag = drag
        // The document's acceptance table: the drag's one reducer call before its drop.
        if let doc = model.docDrag, let items = doc.items(payload) {
            drag.docItems = items
            drag.docAcceptance = doc.begin(items)
        }
        suppressed.formUnion(hidden)
        setHovered(nil)
        for key in hidden { rowViews[key]?.alphaValue = 0 }
        reload(animated: true)
    }
    func updateDrag(windowPoint: NSPoint) {
        guard let drag else { return }
        let started = CACurrentMediaTime()
        defer { lastDragWorkMs = (CACurrentMediaTime() - started) * 1000 }
        if SidebarListPinDrop.holds(self, drag, at: windowPoint) { return }
        if offerHandoff(drag, windowPoint: windowPoint) { return }
        drag.lastWindowPoint = windowPoint
        let point = convert(windowPoint, from: nil)
        // The lifted row follows the pointer vertically; x stays locked. A tile has neighbours beside it: it follows both ways.
        if !drag.restShaped {
            SidebarReorderLift.follow(drag.lift, origin: CGPoint(x: point.x - drag.grabOffsetX, y: point.y - drag.grabOffsetY), visible: visibleRect)
        } else {
            SidebarReorderLift.follow(drag.lift, top: point.y - drag.grabOffsetY, visible: visibleRect)
        }
        autoscroll.update(windowPoint: windowPoint)
        let card = drag.probeCard
        if point.y != drag.lastY {
            drag.movingUp = point.y < drag.lastY
            drag.lastY = point.y
        }
        if drag.docItems != nil { return updateDocDrag(drag, point: point) }
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
        if let items = drag.docItems, let doc = model.docDrag {
            guard let target = drag.docTarget else { return cancelDrag() }
            // The list keeps the drop's look until the move lands; the card settles into the slot it shows.
            settling = SidebarSettlingDrop(drag: drag, revision: model.sectionsRevision, blocks: blocks)
            self.drag = nil
            revealedActive = nil
            doc.drop(items, target)
            settling?.key = SidebarDocStore.current?.lastIntentKey // nil already: refused inside the call
            suppressed = drag.hiddenKeys
            reload(animated: true)
            return land(drag, at: settling == nil ? nil : settleFrame(drag))
        }
        guard let target = drag.target else { return cancelDrag() }
        self.drag = nil
        revealedActive = nil // A drop moves rows, not the list: its reload anchors on the first visible row (cx-fnfj).
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
        case (.group, .intoGroup), (.group, .ontoWorkspace), (.item, _):
            break
        }
        suppressed = drag.hiddenKeys // Rows land under the lifted view, stay hidden until it arrives.
        reload(animated: true)
        land(drag)
    }
    /// A document drag's move: geometry only (no reducer call, no layout
    /// pass after the first), then the list shows the drop as before.
    private func updateDocDrag(_ drag: Drag, point: NSPoint) {
        guard let doc = model.docDrag else { return }
        if drag.docGeometry == nil {
            drag.geometryRevision = model.sectionsRevision
            drag.blockBases = blockBases()
            let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
            drag.docGeometry = doc.geometry(base, width: bounds.width, acceptance: drag.docAcceptance, blocks: drag.blockBases)
        }
        guard let (geometry, rows) = drag.docGeometry else { return }
        // The rest shape's centre under the pointer: it does not move when the card morphs (no hit oscillation at a block edge).
        let displayY = drag.morphs || drag.tileSource != nil ? point.y - drag.grabOffsetY * drag.restFrame.height / max(1, drag.lift.frame.height)
            + drag.restFrame.height / 2 : drag.probeCard.midY
        let y = drag.blockTarget != nil ? baseY(displayY: displayY, blockGap: drag.blockTarget, bases: drag.blockBases)
            : SidebarDragGeometry.baseY(displayY: displayY, gapY: displayed.gapY, gapHeight: displayed.gapShift)
        guard let hit = geometry.hit(CGPoint(x: point.x, y: y)) else {
            // Nowhere to drop: no gap shows.
            drag.docTarget = nil
            drag.lift.setRefused(true)
            if drag.target != nil || drag.blockTarget != nil {
                (drag.target, drag.blockTarget) = (nil, nil)
                reload(animated: true)
            }
            return
        }
        drag.probe = SidebarDropProbe(hit, displayY: displayY, baseY: y)
        drag.docTarget = hit.target
        drag.lift.setRefused(hit.target == nil)
        // A list row shows the list's gap or group fill; a block's item opens a gap among the block's items.
        var target: DropTarget?
        var blockTarget: SidebarBlockGap?
        if let docTarget = hit.target {
            if let row = rows[hit.slot.key] {
                target = SidebarDocDrag.display(hit, row: row)
            } else {
                blockTarget = SidebarBlockGap(section: hit.slot.section,
                                              index: blockIndex(docTarget, section: hit.slot.section, moving: drag.docItems ?? []))
            }
        }
        guard target != drag.target || blockTarget != drag.blockTarget else { return }
        drag.target = target
        drag.blockTarget = blockTarget
        reload(animated: true)
        morphLift(drag, point: point)
    }

    /// Shapes the card as the drop will look (DESIGN "Drag feel" 2): the
    /// block slot it opens (a tile, a chip, an item row), else its list row,
    /// indented under a group's line when it goes into a group. The pointer
    /// keeps the same relative grab point on the card.
    func morphLift(_ drag: Drag, point: NSPoint) {
        guard drag.morphs || drag.tileSource != nil else { return }
        var shape = drag.restFrame
        var rest = true
        if let gap = drag.blockTarget, let slot = blockSlotFrame(gap) {
            shape = slot
            rest = false
        } else if drag.tileSource != nil || drag.restShaped == false {
            shape = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: metrics.rowHeight)
        }
        if rest, case let .position(position)? = drag.target, position.group != nil {
            shape.origin.x = inset + SidebarStyle.groupGutter
            shape.size.width = max(0, bounds.width - inset * 2 - SidebarStyle.groupGutter)
        }
        let old = drag.lift.frame
        guard shape.size != old.size || (rest && shape.minX != old.minX) else { return }
        let sx = old.width > 0 ? shape.width / old.width : 1, sy = old.height > 0 ? shape.height / old.height : 1
        drag.grabOffsetX *= sx
        drag.grabOffsetY *= sy
        drag.restShaped = rest
        let x = rest ? shape.minX : point.x - drag.grabOffsetX
        drag.lift.morph(to: NSRect(x: x, y: point.y - drag.grabOffsetY, width: shape.width, height: shape.height))
    }

    func cancelDrag() {
        guard let drag else { return }
        autoscroll.stop()
        SidebarListPinDrop.end(self)
        self.drag = nil
        press?.cancelled = true
        if let source = drag.tileSource { drag.tileRegion?.docSpentPress = source.item } // the tile's press drags nothing more
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }
    /// Flies the lifted view to its row's current frame (or `slot`, the
    /// band slot of a pin drop), then swaps it out and runs `then`.
    func land(_ drag: Drag, at slot: NSRect? = nil, then: (@MainActor () -> Void)? = nil) {
        let tile = drag.tileSource.flatMap { source in drag.tileRegion?.itemView(source.item).map { convert($0.bounds, from: $0) } }
        let destination = slot ?? tile
            ?? SidebarListLift.blockFrame(self, SidebarListLift.rows(self, for: drag.grabbedKey, hidden: drag.hiddenKeys)) ?? drag.lift.frame
        SidebarReorderLift.land(drag.lift, at: destination) { [weak self] in
            defer { then?() }
            guard let self else { return }
            self.suppressed.subtract(drag.hiddenKeys)
            for key in drag.hiddenKeys { self.rowViews[key]?.alphaValue = 1 }
            self.updateHover()
            if let anchor = drag.renameOnLand { self.inlineRename.beginGroup(of: anchor) }
        }
    }
}
