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
@MainActor
final class CloudTreeMachineReorderLift: NSObject {
    private weak var outline: CloudTreeNSOutlineView?

    private struct Session {
        let sequence: Int
        let sourceID: String
        let layout: CloudTreeReorderLiftLayout
        let sourceRows: Range<Int>
        /// Where the press landed. Only the pointer's travel from here picks
        /// the slot; closing the machines above must not count as a move.
        let grabY: CGFloat
        /// How far closing the machines above moved the held row up. The row
        /// starts there, under the hand, and glides into its closed slot.
        let closeShift: CGFloat
        let startTime: CFTimeInterval
        /// Machines closed for the drag, opened again when it ends.
        let collapsedIDs: [String]
        var placement: CloudTreeReorderLiftLayout.Placement
        /// The translation each row was last sent toward, so a row only
        /// starts a new glide when its target flips.
        var targets: [Int: CGFloat] = [:]
    }

    private var session: Session?
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
    var sourceNodeID: String? { session?.sourceID }

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
        isPeer: (CloudTreeNode) -> Bool, closes: (CloudTreeNode) -> Bool, onLeave: (() -> Void)? = nil,
        collapse: ([CloudTreeNode]) -> Void
    ) -> Bool {
        guard let outline else { return false }
        discard()
        let before = visualTops()
        let closing = siblings.compactMap { outline.findItem(nodeID: $0.id) }
            .filter { closes($0) && outline.isItemExpanded($0) }
        let ghosts = closing.isEmpty ? [] : makeGhosts(under: Set(closing.map(\.id)))
        if !closing.isEmpty { collapse(closing) }

        // Collapsing an expanded sibling changes row indexes immediately, but
        // AppKit can defer the corresponding geometry pass. Read post-collapse
        // frames only after layout, or a source near the bottom of a tree with
        // open children starts visibly offset from the pointer.
        outline.layoutSubtreeIfNeeded()

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
        let newTop = frames[sourceRows.lowerBound].minY
        let oldTop = before[source.id] ?? newTop
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        session = Session(
            sequence: sequence, sourceID: source.id, layout: layout, sourceRows: sourceRows,
            grabY: pressY ?? outline.lastMouseDownPoint?.y ?? pointerY() ?? newTop,
            closeShift: reduceMotion ? 0 : oldTop - newTop, startTime: CACurrentMediaTime(),
            collapsedIDs: closing.map(\.id),
            placement: layout.placement(dragOffset: 0)
        )
        self.onLeave = onLeave
        animateGhosts(ghosts, before: before)
        land(from: before, excluding: source.id, fadingIn: false)
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

    /// The part of the close shift the held row still carries: a critically
    /// damped glide from under the hand into its closed slot.
    private static func remainingCloseShift(_ session: Session) -> CGFloat {
        guard session.closeShift != 0 else { return 0 }
        let omega = 17.0
        let t = max(0, CACurrentMediaTime() - session.startTime)
        let remaining = exp(-omega * t) * (1 + omega * t)
        return remaining < 0.002 ? 0 : session.closeShift * CGFloat(remaining)
    }

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
                Self.setShift(placement.sourceOffset + Self.remainingCloseShift(session), on: layer)
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
        guard let session, outline != nil else { return false }
        displayLink?.invalidate()
        displayLink = nil
        onLeave = nil
        let before = visualTops()
        resetTouched()
        self.session = nil
        isFinishing = true
        let result = mutate?() ?? false
        reopen(session.collapsedIDs)
        // Row views exist only after layout; landing before it would snap.
        outline?.layoutSubtreeIfNeeded()
        isFinishing = false
        land(from: before, excluding: nil, fadingIn: true, liftedID: session.sourceID)
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

    /// Where each visible row is on screen right now, by node id: its frame
    /// plus whatever translation it is showing mid-flight.
    private func visualTops() -> [String: CGFloat] {
        guard let outline else { return [:] }
        var tops: [String: CGFloat] = [:]
        outline.enumerateAvailableRowViews { rowView, row in
            guard let node = outline.item(atRow: row) as? CloudTreeNode else { return }
            let shift = (rowView.layer?.presentation() ?? rowView.layer)
                .flatMap { $0.value(forKeyPath: "transform.translation.y") as? CGFloat } ?? 0
            tops[node.id] = outline.rect(ofRow: row).minY + shift
        }
        return tops
    }

    /// Springs every visible row from its old on-screen top to its frame.
    /// A row that was not on screen before (a machine's rows opening again)
    /// travels with its machine and fades in.
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
                Self.glide(layer, to: 0)
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

    private func animateGhosts(_ ghosts: [Ghost], before: [String: CGFloat]) {
        guard let outline, !ghosts.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { ghosts.forEach { $0.layer.removeFromSuperlayer() } }
        }
        let machinesByID = outline.visibleItemsByID()
        for ghost in ghosts {
            // The rows fold toward where their machine now stands.
            var travel: CGFloat = 0
            if let machine = machinesByID[ghost.machineID], let old = before[ghost.machineID] {
                let row = outline.row(forItem: machine)
                if row >= 0 { travel = outline.rect(ofRow: row).minY - old }
            }
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = 0
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
    /// from where the row is on screen so a retarget mid-glide never jumps.
    /// Explicit animation: a view's backing layer ignores implicit actions.
    private static func glide(_ layer: CALayer, to target: CGFloat) {
        let current = (layer.presentation() ?? layer).value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
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
