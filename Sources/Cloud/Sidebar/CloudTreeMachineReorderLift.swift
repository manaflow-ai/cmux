import AppKit
import CmuxCloud
import QuartzCore

/// The visuals of a continuous machine or workspace drag in the Cloud tree.
///
/// There is no drag image and no insertion line: the real row is what the
/// hand holds. Open rows close for the drag so every peer is one row, the
/// peers part around the lifted row on springs, and the release
/// lands each row from wherever it is on screen. The model is untouched until
/// the drop; during the drag everything is a layer transform over an
/// unchanged outline, laid out by `CloudTreeReorderLiftLayout`.
///
/// The held row never moves on its own. Closing rows, and opening them again
/// at the end, is anchored on it: the list scrolls so the row's slot stays
/// where the row stood, borrowing scroll range past the rows when the list is
/// too short to get there, and gives the range back when the drag ends. The
/// row is the press point plus the pointer's travel, so it stays under the
/// hand for the whole drag, and every row stays reachable by scrolling.
@MainActor
final class CloudTreeMachineReorderLift: NSObject {
    private weak var outline: CloudTreeNSOutlineView?

    private struct Session {
        let sequence: Int
        let sourceID: String
        let layout: CloudTreeReorderLiftLayout
        let sourceRows: Range<Int>
        /// The held row's top in the closed outline.
        let sourceTop: CGFloat
        /// Where on the held row the press landed, from its top.
        let grabOffset: CGFloat
        /// How far the outline was scrolled before the drag, for a drag
        /// dropped without a landing.
        let scrollBefore: CGFloat
        /// Machines closed for the drag, opened again when it ends.
        let collapsedIDs: [String]
        var placement: CloudTreeReorderLiftLayout.Placement
        /// The translation each row was last sent toward, so a row only
        /// starts a new glide when its target flips.
        var targets: [Int: CGFloat] = [:]

        /// The press point in the closed outline. Only the pointer's travel
        /// from here picks the slot, so closing rows is never a move.
        var grabY: CGFloat { sourceTop + grabOffset }
    }

    private var session: Session?
    /// The row being lifted while `begin` closes rows and scrolls, before
    /// the session exists, so hover stays on it through those layouts.
    private var liftingID: String?
    /// Called once when the pointer leaves the outline, for drags that can
    /// continue somewhere else (a workspace onto a pane).
    private var onLeave: (() -> Void)?
    private var displayLink: CADisplayLink?
    /// Row views this drag has moved or styled, reset when it ends.
    private let touched = NSHashTable<NSTableRowView>.weakObjects()
    private var isFinishing = false
    private let liftStyle = CloudTreeMachineLiftStyle()

    private static let shiftKey = "cmux.machineLift.shift"
    private static let liftZ: CGFloat = 10

    init(outline: CloudTreeNSOutlineView) {
        self.outline = outline
    }

    /// The node the hand holds, so hover can stay on it.
    var sourceNodeID: String? { session?.sourceID ?? liftingID }

    func isActive(sequence: Int) -> Bool { session?.sequence == sequence }

    // MARK: Begin

    /// Lifts `source` out of `siblings`. `isPeer` picks the siblings it can
    /// trade places with, `closes` the ones that close for the drag, and
    /// `collapse` closes them without recording it as the person's choice.
    /// `pressY` is where the press landed, before anything closed; it
    /// defaults to the outline's last mouse-down. Returns whether the row lifted.
    @discardableResult
    func begin(
        sequence: Int, source: CloudTreeNode, siblings: [CloudTreeNode], pressY: CGFloat? = nil,
        isPeer: (CloudTreeNode) -> Bool, closes: (CloudTreeNode) -> Bool = { _ in false },
        onLeave: (() -> Void)? = nil, collapse: ([CloudTreeNode]) -> Void = { _ in }
    ) -> Bool {
        guard let outline else { return false }
        discard()
        liftingID = source.id
        defer { liftingID = nil }
        let before = visualTops()
        let scrollBefore = scrollOffset()
        guard let held = outline.findItem(nodeID: source.id) else { return false }
        let heldFrame = outline.rect(ofRow: outline.row(forItem: held))
        let press = pressY ?? outline.lastMouseDownPoint?.y ?? pointerY() ?? heldFrame.midY
        let grabOffset = min(max(press - heldFrame.minY, 0), heldFrame.height)
        let closing = siblings.compactMap { outline.findItem(nodeID: $0.id) }
            .filter { closes($0) && outline.isItemExpanded($0) }
        let ghosts = closing.isEmpty ? [] : makeGhosts(under: Set(closing.map(\.id)))
        if !closing.isEmpty {
            collapse(closing)
            // The document shrinks on the next layout pass, and the clip view
            // may scroll when it does; settle both before anything is measured.
            outline.layoutDocumentNow()
        }

        let frames = (0..<outline.numberOfRows).map { outline.rect(ofRow: $0) }
        var blocks: [CloudTreeReorderLiftLayout.Block] = []
        var sourceIndex: Int?
        var sourceRows: Range<Int>?
        // The caller's tree and the outline's items can be different objects
        // for the same rows, so rows are found by id.
        let displayed = outline.visibleItemsByID()
        for sibling in siblings {
            let row = displayed[sibling.id].map { outline.row(forItem: $0) } ?? -1
            guard row >= 0 else { continue }
            let level = outline.level(forRow: row)
            var end = row + 1
            while end < outline.numberOfRows, outline.level(forRow: end) > level { end += 1 }
            if sibling.id == source.id {
                sourceIndex = blocks.count
                sourceRows = row..<end
            }
            blocks.append(.init(
                rows: row..<end,
                isPeer: sibling.id != source.id && isPeer(sibling)
            ))
        }
        guard let sourceIndex, let sourceRows,
              let layout = CloudTreeReorderLiftLayout(frames: frames, blocks: blocks, sourceIndex: sourceIndex)
        else {
#if DEBUG
            cmuxDebugLog("cloud.lift.begin skip source=\(source.id) found=\(sourceIndex != nil) blocks=\(blocks.count)")
#endif
            ghosts.forEach { $0.layer.removeFromSuperlayer() }
            return false
        }
        let sourceTop = frames[sourceRows.lowerBound].minY
        // The held row's slot stays where the row stood on screen.
        scroll(to: sourceTop - (heldFrame.minY - scrollBefore), borrowing: true)
        outline.layoutSubtreeIfNeeded()
        // Every position from before, in the outline as it now scrolls.
        let scrolled = scrollOffset() - scrollBefore
        session = Session(
            sequence: sequence, sourceID: source.id, layout: layout, sourceRows: sourceRows,
            sourceTop: sourceTop, grabOffset: grabOffset, scrollBefore: scrollBefore,
            collapsedIDs: closing.map(\.id),
            placement: layout.placement(dragOffset: 0)
        )
        self.onLeave = onLeave
#if DEBUG
        cmuxDebugLog(
            "cloud.lift.begin source=\(source.id) closed=\(closing.count) grab=\(Int(grabOffset)) " +
            "scrolled=\(Int(scrolled)) borrowed=\(Int(borrowed.above))/\(Int(borrowed.below))"
        )
#endif
        animateGhosts(ghosts, before: before, scrolled: scrolled)
        land(from: before.mapValues { $0 + scrolled }, excluding: source.id, fadingIn: false)
        if let pointer = pointerY() { update(pointerY: pointer) }

        let link = outline.displayLink(target: self, selector: #selector(tick))
        // .common keeps it firing inside the drag's event-tracking loop.
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    // MARK: Drag

    @objc private func tick() {
        guard session != nil, let pointer = pointer() else { return }
        if let onLeave, let outline,
           !outline.visibleRect.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin).contains(pointer) {
            self.onLeave = nil
            onLeave()
            return
        }
        update(pointerY: pointer.y)
    }

    /// How far past the outline's visible edge the pointer goes before a
    /// drag that can leave hands off to a native drag.
    private static let leaveMargin: CGFloat = 12

    /// Moves the lifted row to the pointer and returns the slot it shows.
    @discardableResult
    func update(pointerY: CGFloat) -> Int? {
        guard var session, let outline else { return nil }
        let placement = session.layout.placement(dragOffset: pointerY - session.grabY)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        outline.enumerateAvailableRowViews { rowView, row in
            rowView.wantsLayer = true
            guard let layer = rowView.layer else { return }
            touched.add(rowView)
            if session.sourceRows.contains(row) {
                // Direct manipulation: never smoothed, or the row lags the hand.
                layer.removeAnimation(forKey: Self.shiftKey)
                Self.setShift(placement.sourceOffset, on: layer)
                layer.zPosition = Self.liftZ
                liftStyle.apply(to: rowView, animated: true)
                return
            }
            liftStyle.remove(from: rowView, animated: false)
            layer.zPosition = 0
            let target = placement.rowOffsets[row] ?? 0
            if session.targets[row, default: 0] != target {
                session.targets[row] = target
                if reduceMotion {
                    layer.removeAnimation(forKey: Self.shiftKey)
                    Self.setShift(target, on: layer)
                } else {
                    Self.glide(layer, to: target)
                }
            } else if layer.animation(forKey: Self.shiftKey) == nil {
                // A row view reused while scrolling arrives with its last
                // tenant's transform; hold every visible row on its target.
                Self.setShift(target, on: layer)
            }
        }
        session.placement = placement
        self.session = session
        return placement.slot
    }

    /// The slot the lifted row shows, for the drop to commit.
    var slot: Int? { session?.placement.slot }

    // MARK: End

    /// Ends the drag. `mutate` lands the new order (a drop), or nil for a
    /// cancel; either way the machines closed for the drag open again and
    /// every row springs from where it is on screen to where it belongs.
    func finish(reopen: ([String]) -> Void, mutate: (() -> Bool)? = nil) -> Bool {
        guard let session, let outline else { return false }
        displayLink?.invalidate()
        displayLink = nil
        onLeave = nil
        let before = visualTops(viewless: { session.placement.rowOffsets[$0] ?? 0 })
        let scrollBefore = scrollOffset()
        resetTouched()
        self.session = nil
        isFinishing = true
        let result = mutate?() ?? false
        reopen(session.collapsedIDs)
        returnScrollRange()
        // Row views exist only after layout; landing before it would snap.
        outline.layoutDocumentNow()
        if rowsFit() {
            // A list with nothing to scroll rests at its top.
            scroll(to: -(outline.enclosingScrollView?.contentInsets.top ?? 0), borrowing: false)
        } else if let held = outline.findItem(nodeID: session.sourceID) {
            // The row lands in the slot it showed (its own on a cancel), and
            // the rows opening again make room around it rather than move it.
            let slot = session.sourceTop + (result ? session.placement.sourceSlotOffset : 0) - scrollBefore
            scroll(to: outline.rect(ofRow: outline.row(forItem: held)).minY - slot, borrowing: false)
        }
        outline.layoutSubtreeIfNeeded()
        let scrolled = scrollOffset() - scrollBefore
        isFinishing = false
        land(from: before.mapValues { $0 + scrolled }, excluding: nil, fadingIn: true, liftedID: session.sourceID)
        return result
    }

    /// Drops the visuals at once: the outline is about to reload under the
    /// drag, or it is leaving its window. A drag that could leave the tree
    /// gets its native image back, as if it had left.
    func discard() {
        guard !isFinishing else { return }
        let leave = onLeave
        displayLink?.invalidate()
        displayLink = nil
        onLeave = nil
        if let session {
            returnScrollRange()
            scroll(to: session.scrollBefore, borrowing: false)
        }
        session = nil
        resetTouched()
        leave?()
    }

    // MARK: Geometry

    private func pointer() -> NSPoint? {
        guard let outline, let window = outline.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return outline.convert(windowPoint, from: nil)
    }

    private func pointerY() -> CGFloat? { pointer()?.y }

    /// Where each row stands right now, by node id: its frame plus whatever
    /// translation it is showing mid-flight. A row with no view (off screen)
    /// stands where `viewless` puts it.
    private func visualTops(viewless: (Int) -> CGFloat = { _ in 0 }) -> [String: CGFloat] {
        guard let outline else { return [:] }
        var shifts: [Int: CGFloat] = [:]
        outline.enumerateAvailableRowViews { rowView, row in
            shifts[row] = (rowView.layer?.presentation() ?? rowView.layer)
                .flatMap { $0.value(forKeyPath: "transform.translation.y") as? CGFloat } ?? 0
        }
        var tops: [String: CGFloat] = [:]
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? CloudTreeNode else { continue }
            tops[node.id] = outline.rect(ofRow: row).minY + (shifts[row] ?? viewless(row))
        }
        return tops
    }

    /// How far the outline is scrolled: the top of what the clip view shows.
    private func scrollOffset() -> CGFloat {
        outline?.enclosingScrollView?.contentView.bounds.minY ?? 0
    }

    /// Scroll range lent to this drag above and below the rows.
    private var borrowed: (above: CGFloat, below: CGFloat) = (0, 0)

    /// Scrolls the clip view to `y`, as near as the document allows. When
    /// `borrowing`, the outline first borrows whatever range past its rows
    /// it takes to get all the way there.
    private func scroll(to y: CGFloat, borrowing: Bool) {
        guard let outline, let scrollView = outline.enclosingScrollView else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = y
        if borrowing, let lend = outline.lendScrollRange {
            let reachable = clip.constrainBoundsRect(bounds).origin.y
            if reachable > y { borrowed.above += reachable - y }
            if reachable < y { borrowed.below += y - reachable }
            if reachable != y { lend(borrowed.above, borrowed.below) }
        }
        let target = clip.constrainBoundsRect(bounds).origin.y
        guard abs(target - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func returnScrollRange() {
        guard borrowed.above != 0 || borrowed.below != 0 else { return }
        borrowed = (0, 0)
        outline?.lendScrollRange?(0, 0)
    }

    /// Whether every row fits on screen without scrolling.
    private func rowsFit() -> Bool {
        guard let outline, let scrollView = outline.enclosingScrollView else { return true }
        guard outline.numberOfRows > 0 else { return true }
        let insets = scrollView.contentInsets
        return outline.rect(ofRow: outline.numberOfRows - 1).maxY + insets.top + insets.bottom
            <= scrollView.contentView.bounds.height
    }

    /// Springs every visible row from its old top to its frame. A row that
    /// was not there before (a machine's rows opening again) travels with
    /// its machine and fades in.
    private func land(
        from before: [String: CGFloat], excluding excludedID: String?, fadingIn: Bool, liftedID: String? = nil
    ) {
        guard let outline else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The lifted row stays above its neighbours until every glide in
        // this transaction has landed.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session == nil else { return }
                for rowView in self.touched.allObjects { rowView.layer?.zPosition = 0 }
            }
        }
        defer { CATransaction.commit() }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let node = outline.item(atRow: row) as? CloudTreeNode, node.id != excludedID else { return }
            rowView.wantsLayer = true
            guard let layer = rowView.layer else { return }
            let top = outline.rect(ofRow: row).minY
            var delta: CGFloat?
            var appearing = false
            if let old = before[node.id] {
                delta = old - top
            } else if fadingIn {
                appearing = true
                var parent = outline.parent(forItem: node) as? CloudTreeNode
                while let candidate = parent, before[candidate.id] == nil {
                    parent = outline.parent(forItem: candidate) as? CloudTreeNode
                }
                if let parent, let old = before[parent.id] {
                    let parentRow = outline.row(forItem: parent)
                    if parentRow >= 0 { delta = old - outline.rect(ofRow: parentRow).minY }
                }
            }
            touched.add(rowView)
            if node.id == liftedID {
                layer.zPosition = Self.liftZ
                liftStyle.apply(to: rowView, animated: false)
                liftStyle.remove(from: rowView, animated: !reduceMotion)
            }
            guard !reduceMotion else { return }
            if let delta, abs(delta) > 0.5 {
                Self.setShift(delta, on: layer)
                Self.glide(layer, from: delta, to: 0)
            }
            if appearing {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.22
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "cmux.machineLift.fadeIn")
            }
        }
    }

    private func resetTouched() {
        for rowView in touched.allObjects {
            guard let layer = rowView.layer else { continue }
            layer.removeAnimation(forKey: Self.shiftKey)
            Self.setShift(0, on: layer)
            layer.zPosition = 0
            liftStyle.remove(from: rowView, animated: false)
        }
        touched.removeAllObjects()
    }

    // MARK: Closing machines

    /// Pictures of the rows that are about to close, so they can fade out
    /// into their machine or workspace instead of vanishing.
    private struct Ghost {
        let layer: CALayer
        let machineID: String
    }

    private func makeGhosts(under machineIDs: Set<String>) -> [Ghost] {
        guard let outline, let host = outline.layer,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return [] }
        var ghosts: [Ghost] = []
        outline.enumerateAvailableRowViews { rowView, row in
            guard var item = outline.item(atRow: row) else { return }
            var machineID: String?
            while let parent = outline.parent(forItem: item) {
                if let node = parent as? CloudTreeNode, machineIDs.contains(node.id) { machineID = node.id }
                item = parent
            }
            guard let machineID,
                  let bitmap = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return }
            rowView.cacheDisplay(in: rowView.bounds, to: bitmap)
            let image = NSImage(size: rowView.bounds.size)
            image.addRepresentation(bitmap)
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.frame = rowView.frame
            host.addSublayer(layer)
            ghosts.append(Ghost(layer: layer, machineID: machineID))
        }
        return ghosts
    }

    /// Folds each picture toward where its machine now stands. `before` is
    /// from before the rows closed; `scrolled` is how far the outline has
    /// scrolled since, which the pictures undo so they start where they were.
    private func animateGhosts(_ ghosts: [Ghost], before: [String: CGFloat], scrolled: CGFloat) {
        guard let outline, !ghosts.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { ghosts.forEach { $0.layer.removeFromSuperlayer() } }
        }
        let machinesByID = outline.visibleItemsByID()
        for ghost in ghosts {
            // The rows fold toward where their machine now stands.
            var travel = scrolled
            if let machine = machinesByID[ghost.machineID], let old = before[ghost.machineID] {
                let row = outline.row(forItem: machine)
                if row >= 0 { travel = outline.rect(ofRow: row).minY - old }
            }
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = scrolled
            move.toValue = travel
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.18
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.layer.opacity = 0
            ghost.layer.transform = CATransform3DMakeTranslation(0, travel, 0)
            ghost.layer.add(group, forKey: "cmux.machineLift.ghost")
        }
        CATransaction.commit()
    }

    // MARK: Layer motion

    private static func setShift(_ y: CGFloat, on layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, y, 0)
        CATransaction.commit()
    }

    /// Glides a row's vertical shift to `target` on a soft spring, starting
    /// from `start`, or from where the row is on screen so a retarget
    /// mid-glide never jumps. Explicit animation: a view's backing layer
    /// ignores implicit actions.
    private static func glide(_ layer: CALayer, from start: CGFloat? = nil, to target: CGFloat) {
        let current = start
            ?? (layer.presentation() ?? layer).value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        let spring = CASpringAnimation(keyPath: "transform.translation.y")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 300
        spring.damping = 30
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: shiftKey)
        setShift(target, on: layer)
    }
}

extension NSOutlineView {
    /// Resolves all visible Cloud nodes in one pass for drag cleanup and animation.
    func visibleItemsByID() -> [String: CloudTreeNode] {
        var result: [String: CloudTreeNode] = [:]
        for row in 0..<numberOfRows {
            if let node = item(atRow: row) as? CloudTreeNode { result[node.id] = node }
        }
        return result
    }

    /// The displayed item for a Cloud node id, if it is on a visible row.
    func findItem(nodeID: String) -> CloudTreeNode? { visibleItemsByID()[nodeID] }
}
