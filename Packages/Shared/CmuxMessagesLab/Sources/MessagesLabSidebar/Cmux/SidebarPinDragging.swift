import AppKit

/// cmux: Messages' pin drags on the pinned grid. Press a tile and drag: it lifts and follows
/// the pointer, the other tiles slide to make room, the drop places it (`SidebarPinPlacing`).
/// A tile dropped on the list is unpinned; a row dropped on the grid is pinned there; Escape
/// puts everything back. Drags are off while searching (the grid is hidden then).
extension SidebarController {
    /// The grid's order as drawn during a drag (nil: no drag). Tests read it.
    var pinDragOrder: [ConversationID]? { pinDragState.drag?.order }

    private var placer: SidebarPinPlacing? { delegate as? SidebarPinPlacing }
    private var tileSize: CGSize { CGSize(width: metrics.tileWidth, height: metrics.tileHeight) }

    /// The mouse-down tracking loop (SidebarDocumentView.mouseDown): a drag starts after 4 pt.
    func trackPinDrag(from down: NSEvent, in view: NSView) {
        guard let window = view.window, placer != nil, query.isEmpty else { return }
        let start = view.convert(down.locationInWindow, from: nil)
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch e.type {
            case .leftMouseDragged:
                let p = view.convert(e.locationInWindow, from: nil)
                if !dragging {
                    guard hypot(p.x - start.x, p.y - start.y) >= 4 else { continue }
                    guard beginPinDrag(at: start) else { return }
                    dragging = true
                }
                _ = view.autoscroll(with: e)
                movePinDrag(to: view.convert(e.locationInWindow, from: nil))
            case .leftMouseUp:
                if dragging { endPinDrag() }
                return
            case .keyDown where e.keyCode == 53:
                if dragging { cancelPinDrag() }
                return
            default:
                continue
            }
        }
    }

    /// Lifts the tile or row under `p` (document coordinates). False: nothing to drag there.
    @discardableResult
    func beginPinDrag(at p: CGPoint) -> Bool {
        guard pinDragState.drag == nil, placer != nil, query.isEmpty, let h = hit(p) else { return false }
        let c = snapshot.items[item(h)]
        guard !Self.isExtra(c.id), delegate?.sidebar(self, actionsFor: c.id).contains(.pin) == true else { return false }
        let state = pinDragState
        let frame: CGRect
        switch h {
        case let .tile(t):
            frame = tileRect(t)
            state.drag = SidebarPinDrag(id: c.id, source: .tile, pinned: pinnedItems.map { snapshot.items[$0].id })
        case .row:
            frame = CGRect(x: p.x - tileSize.width / 2, y: p.y - tileSize.height / 2, width: tileSize.width, height: tileSize.height)
            state.drag = SidebarPinDrag(id: c.id, source: .row, pinned: pinnedItems.map { snapshot.items[$0].id })
        }
        state.grab = CGSize(width: p.x - frame.midX, height: p.y - frame.midY)
        mouseMoved(nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        state.ghost?.removeFromSuperlayer()
        let ghost: CALayer
        if case let .tile(t) = h { ghost = copyOfTile(tileLayers[t]) } else { ghost = avatarGhost(c) }
        ghost.frame = frame
        ghost.zPosition = 20
        ghost.shadowOpacity = 0.22
        ghost.shadowRadius = 10
        ghost.shadowOffset = CGSize(width: 0, height: 4)
        ghost.opacity = 0.96
        document.layer?.addSublayer(ghost)
        state.ghost = ghost
        if case let .tile(t) = h { tileLayers[t].isHidden = true }
        CATransaction.commit()
        let lift = CABasicAnimation(keyPath: "transform.scale")
        lift.fromValue = 1
        lift.toValue = SidebarPinDragState.lift
        lift.duration = 0.15
        ghost.transform = CATransform3DMakeScale(SidebarPinDragState.lift, SidebarPinDragState.lift, 1)
        ghost.add(lift, forKey: "cmux.pinDrag.lift")
        return true
    }

    /// The dragged tile as drawn (no selection), from its parts: one bitmap per tile, or the
    /// layered tile's avatar, name and bubble.
    private func copyOfTile(_ tile: SidebarRowLayer) -> CALayer {
        let ghost = CALayer()
        ghost.bounds = tile.bounds
        for part in [tile.avatar, tile.dot, tile.content, tile.time] where !part.isHidden && (part.contents != nil || part.backgroundColor != nil) {
            let copy = CALayer()
            copy.frame = part.frame
            copy.contents = part.contents
            copy.contentsGravity = part.contentsGravity
            copy.contentsScale = part.contentsScale
            copy.minificationFilter = part.minificationFilter
            copy.backgroundColor = part.backgroundColor
            copy.cornerRadius = part.cornerRadius
            ghost.addSublayer(copy)
        }
        return ghost
    }

    /// A row lifted toward the grid: its avatar at the tile's avatar place.
    private func avatarGhost(_ c: ConversationSummary) -> CALayer {
        let ghost = CALayer()
        ghost.bounds = CGRect(origin: .zero, size: tileSize)
        let avatar = CALayer()
        avatar.frame = SidebarDraw.tileAvatar(metrics)
        avatar.contents = avatars.image(c.avatar, diameter: SidebarMetrics.pinMaxAvatar, ctx: renderContext)
        avatar.contentsGravity = .resize
        avatar.contentsScale = renderContext.scale
        avatar.minificationFilter = .trilinear
        ghost.addSublayer(avatar)
        return ghost
    }

    /// The pointer moved to `p`: the ghost follows, the grid makes room where it would land.
    func movePinDrag(to p: CGPoint) {
        let state = pinDragState
        guard var drag = state.drag else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        state.ghost?.position = CGPoint(x: p.x - state.grab.width, y: p.y - state.grab.height)
        CATransaction.commit()
        drag.target = gridSlot(p, count: drag.source == .tile ? drag.pinned.count : drag.pinned.count + 1)
        let changed = drag.target != state.drag?.target
        state.drag = drag
        layoutPinPreview(animated: changed)
    }

    func endPinDrag() { finishPinDrag(cancelled: false) }
    func cancelPinDrag() { finishPinDrag(cancelled: true) }

    /// The grid slot under `p` for a grid of `count` tiles; nil below the grid.
    private func gridSlot(_ p: CGPoint, count: Int) -> Int? {
        guard count > 0, p.y < metrics.pinnedHeight(count: count) else { return nil }
        let cols = metrics.columns
        let rows = (count + cols - 1) / cols
        let col = min(cols - 1, max(0, Int(((p.x - metrics.tileRect(0).minX) / metrics.tileWidth).rounded(.down))))
        let row = min(rows - 1, max(0, Int((max(0, p.y) / metrics.tileHeight).rounded(.down))))
        return min(row * cols + col, count - 1)
    }

    /// Tiles to their slots in the drawn order; the rows below follow the grid's drawn height.
    private func layoutPinPreview(animated: Bool) {
        guard let drag = pinDragState.drag else { return }
        let order = drag.order
        for t in pinnedItems.indices where t < tileLayers.count {
            let id = snapshot.items[pinnedItems[t]].id
            guard id != drag.id, let slot = order.firstIndex(of: id) else { continue }
            slide(tileLayers[t], to: tileRect(slot), animated: animated)
        }
        let dy = metrics.pinnedHeight(count: order.count) - pinnedHeight
        for l in listRowLayers() { shift(l, by: dy, animated: animated) }
    }

    private func finishPinDrag(cancelled: Bool) {
        let state = pinDragState
        guard var drag = state.drag else { return }
        if cancelled { drag.cancel() }
        // Where each tile is drawn now, for the landing once the host has reloaded.
        var drawn: [ConversationID: CGRect] = [:]
        for t in pinnedItems.indices where t < tileLayers.count {
            drawn[snapshot.items[pinnedItems[t]].id] = (tileLayers[t].presentation() ?? tileLayers[t]).frame
        }
        if let ghost = state.ghost {
            let at = (ghost.presentation() ?? ghost).position
            drawn[drag.id] = CGRect(x: at.x - tileSize.width / 2, y: at.y - tileSize.height / 2, width: tileSize.width, height: tileSize.height)
        }
        state.drawnGridBottom = pinnedHeight + (listRowLayers().first.map { ($0.presentation() ?? $0).transform.m42 } ?? 0)
        state.drag = nil
        state.landing = drawn
        state.landingID = drag.id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Back to the list's own layout; the host's reload and `landPinDrag` animate from `drawn`.
        for (t, l) in tileLayers.enumerated() {
            l.isHidden = false
            l.removeAnimation(forKey: "cmux.pinDrag.position")
            if t < pinnedItems.count { l.frame = tileRect(t) }
        }
        for l in listRowLayers(includeHidden: true) {
            l.removeAnimation(forKey: "cmux.pinDrag.shift")
            l.transform = CATransform3DIdentity
        }
        switch drag.outcome {
        case .none: break
        case let .place(id, index): placer?.sidebar(self, place: id, at: index)
        case let .unpin(id): setPinned(false, id)
        }
        // A host that reloads later (or refuses) still gets a landing now, against the current layout.
        landPinDrag()
        CATransaction.commit()
    }

    /// After a reload (SidebarView.applyRows): a drag under way follows the new data, and a
    /// drop's tiles slide from where they were drawn into their new places.
    func pinDragDidReload() {
        if let drag = pinDragState.drag {
            let now = pinnedItems.map { snapshot.items[$0].id }
            guard now == drag.pinned, summary(drag.id) != nil else { cancelPinDrag(); return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if drag.source == .tile, let t = now.firstIndex(of: drag.id), t < tileLayers.count { tileLayers[t].isHidden = true }
            CATransaction.commit()
            layoutPinPreview(animated: false)
            return
        }
        landPinDrag()
    }

    private func landPinDrag() {
        let state = pinDragState
        guard let drawn = state.landing else { return }
        state.landing = nil
        let landingID = state.landingID
        var landedAsTile = false
        for t in pinnedItems.indices where t < tileLayers.count {
            let l = tileLayers[t], id = snapshot.items[pinnedItems[t]].id
            l.zPosition = id == landingID ? 1 : 0
            guard let from = drawn[id] else { continue }
            if id == landingID {
                landedAsTile = true
                let settle = CABasicAnimation(keyPath: "transform.scale")
                settle.fromValue = SidebarPinDragState.lift
                settle.toValue = 1
                settle.duration = 0.25
                l.add(settle, forKey: "cmux.pinDrag.settle")
            }
            if from.origin != l.frame.origin { animatePosition(l, from: CGPoint(x: from.midX, y: from.midY)) }
        }
        // The rows: from the grid bottom they were drawn under to the new one.
        let residual = state.drawnGridBottom - pinnedHeight
        if residual != 0 {
            for l in listRowLayers() {
                let a = spring("transform.translation.y")
                a.fromValue = residual
                a.toValue = 0
                l.add(a, forKey: "cmux.pinDrag.shift")
            }
        }
        guard let ghost = state.ghost else { return }
        state.ghost = nil
        if landedAsTile { ghost.removeFromSuperlayer(); return }
        // Unpinned, or a row that stayed a row: the ghost's avatar shrinks onto the row's avatar and fades.
        let ar = SidebarDraw.tileAvatar(metrics)
        let scale = SidebarMetrics.avatar / max(1, ar.width)
        var to = ghost.position
        if let id = landingID, case let .row(r)? = position(of: id) {
            let offset = CGPoint(x: ar.midX - tileSize.width / 2, y: ar.midY - tileSize.height / 2)
            to = CGPoint(x: metrics.rowAvatarX + SidebarMetrics.avatar / 2 - offset.x * scale, y: rowRect(r).midY - offset.y * scale)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setDisableActions(false) // this runs inside the drop's no-animation transaction
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.position = to
        ghost.opacity = 0
        ghost.shadowOpacity = 0
        ghost.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    /// The list's row layers (pinned tiles are not rows); hidden ones are pooled.
    private func listRowLayers(includeHidden: Bool = false) -> [SidebarRowLayer] {
        let tiles = Set(tileLayers.map(ObjectIdentifier.init))
        return (document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
            .filter { !tiles.contains(ObjectIdentifier($0)) && (includeHidden || !$0.isHidden) }
    }

    private func spring(_ keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = 320
        a.damping = 30
        a.duration = a.settlingDuration
        return a
    }

    private func animatePosition(_ l: CALayer, from: CGPoint) {
        let a = spring("position")
        a.fromValue = NSValue(point: from)
        a.toValue = NSValue(point: l.position)
        l.add(a, forKey: "cmux.pinDrag.position")
    }

    private func slide(_ l: CALayer, to frame: CGRect, animated: Bool) {
        guard l.frame != frame else { return }
        let from = (l.presentation() ?? l).position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.frame = frame
        CATransaction.commit()
        if animated { animatePosition(l, from: from) }
    }

    private func shift(_ l: CALayer, by dy: CGFloat, animated: Bool) {
        guard l.transform.m42 != dy else { return }
        let from = (l.presentation() ?? l).transform.m42
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.transform = CATransform3DMakeTranslation(0, dy, 0)
        CATransaction.commit()
        guard animated else { return }
        let a = spring("transform.translation.y")
        a.fromValue = from
        a.toValue = dy
        l.add(a, forKey: "cmux.pinDrag.shift")
    }
}
