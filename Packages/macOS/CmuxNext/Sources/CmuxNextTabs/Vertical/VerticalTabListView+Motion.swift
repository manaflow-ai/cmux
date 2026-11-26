import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens

/// The list's motion, the sidebar's (`SidebarRowMotion`, `SidebarDragSpring`): every row, group line and group pane
/// springs on `.move` to where the layout puts it, so a reorder, a group fold or a drop moves the rows instead of
/// jumping them. While a tab is dragged it lifts under the pointer and the other rows spring aside to open a gap
/// where it would land (`VerticalTabListLayout.preview`). Springs step on the window's one `MotionClock`; with
/// movement off (the tabs category, Reduce Motion, a live resize) every frame lands at once.
struct VerticalTabMotion {
    var rows: [VerticalTabListLayout.RowKind: AnimatedFrame] = [:]
    var lines: [TabGroupID: AnimatedFrame] = [:]
    var panes: [TabGroupID: AnimatedFrame] = [:]
}

extension VerticalTabListView {
    /// The rows as they show now: the drag's preview while a tab is lifted, else the model's layout.
    var shownLayout: VerticalTabListLayout {
        guard let drag, drag.isActive, let slot = drag.slot else { return listLayout }
        return listLayout.preview(dragging: drag.id, on: slot, showsNewTab: model.showsNewTabButton)
    }

    /// Springs every frame toward `shownLayout`. `animated` false (a resize, a density change) lands them now.
    func retargetMotion(animated: Bool) {
        let layout = shownLayout
        let moves = animated && window != nil && Motion.tabs.animatesMovement(in: window) && Motion.canAnimate(in: self)
        func update<Key: Hashable>(_ springs: inout [Key: AnimatedFrame], _ targets: [(Key, CGRect)]) {
            var next: [Key: AnimatedFrame] = [:]
            for (key, rect) in targets {
                if var spring = springs[key], moves {
                    spring.setTarget(rect, alpha: 1)
                    next[key] = spring
                } else if moves {
                    // A row that appears (a group unfolding, a new tab) fades in at its place, as the sidebar's.
                    var spring = AnimatedFrame(rect, alpha: 0)
                    spring.setTarget(rect, alpha: 1)
                    next[key] = spring
                } else {
                    next[key] = AnimatedFrame(rect)
                }
            }
            springs = next
        }
        update(&motion.rows, layout.rows.map { ($0.kind, $0.frame) })
        update(&motion.lines, layout.groupLines.map { ($0.group, $0.frame) })
        update(&motion.panes, layout.groupPanes.map { ($0.group, $0.frame) })
        if moves { runMotion() } else { stopMotion() }
        needsDisplay = true
    }

    /// Where a row draws now (content coordinates).
    func shownFrame(_ row: VerticalTabListLayout.Row) -> CGRect { motion.rows[row.kind]?.rect ?? row.frame }
    func shownAlpha(_ row: VerticalTabListLayout.Row) -> CGFloat { min(max(motion.rows[row.kind]?.alpha.value ?? 1, 0), 1) }

    /// The lifted row under the pointer (content coordinates), the size of its slot.
    func liftedFrame() -> CGRect? {
        guard let drag, drag.isActive, let row = listLayout.rows.first(where: { Self.tabID($0.kind) == drag.id }) else { return nil }
        let y = min(max(drag.pointer.y - drag.grab.y, 0), max(0, listLayout.contentHeight - row.frame.height))
        let pinned: Bool = if case .pinned = row.kind { true } else { false }
        let x = pinned ? drag.pointer.x - drag.grab.x : row.frame.minX
        return CGRect(x: x, y: y, width: row.frame.width, height: row.frame.height)
    }

    /// The drop: the lifted row springs from under the pointer into the slot the model gives it.
    func landLifted(_ id: TabID, from frame: CGRect) {
        for kind in [VerticalTabListLayout.RowKind.tab(id), .pinned(id)] where motion.rows[kind] != nil {
            motion.rows[kind] = AnimatedFrame(frame)
        }
        retargetMotion(animated: true)
    }

    func runMotion() {
        let clock = MotionClock.forView(self)
        if let motionClock, motionClock !== clock { motionClock.stop(self) }
        motionClock = clock
        clock.run(self, trace: "tabs.vertical")
    }

    func stopMotion() {
        motionClock?.stop(self)
        motionClock = nil
    }
}

extension VerticalTabListView: MotionAnimating {
    public func motionStep(_ dt: Double) -> Bool {
        let spring = Motion.tabs.spring(.move)
        var moving = false
        for key in Array(motion.rows.keys) { moving = motion.rows[key]!.advance(dt, parameters: spring) || moving }
        for key in Array(motion.lines.keys) { moving = motion.lines[key]!.advance(dt, parameters: spring) || moving }
        for key in Array(motion.panes.keys) { moving = motion.panes[key]!.advance(dt, parameters: spring) || moving }
        needsDisplay = true
        return moving
    }

    public func motionSettle() {
        for key in Array(motion.rows.keys) { motion.rows[key]!.snap() }
        for key in Array(motion.lines.keys) { motion.lines[key]!.snap() }
        for key in Array(motion.panes.keys) { motion.panes[key]!.snap() }
        needsDisplay = true
    }
}
