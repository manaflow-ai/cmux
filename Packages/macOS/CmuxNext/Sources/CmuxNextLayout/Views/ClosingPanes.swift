import CoreGraphics
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c (`motion.frameOwner.contentPolicy`, read at the close): the panes a springing close took out
/// of one screen, each still shown on its own frame with only its own ground (`PaneHostView.showClosingGround`).
///
/// A closing pane collapses on its neighbours' spring. Each of its edges that a neighbour closes over rides that
/// neighbour's facing edge: it starts there, with its velocity, and springs to where that edge rests, on the same spring
/// (the springs are linear, so the two edges stay together in every frame). The closing pane therefore shows exactly the
/// space its neighbours have not covered yet. When neighbours close over both sides, the leading (top) side keeps the gap
/// it had (the divider that stays), so the pane rests at zero width where they meet. An edge no neighbour closes over
/// (the screen's edge, a docked column's side, a neighbour that does not move) stays where it shows. A later change
/// during the close (another close, a key resize) retargets each edge from its neighbour's new rest. Chrome's tab close
/// does the same: the closing tab shrinks to zero width on the strip's own animation. Its host goes when the motion lands
/// (`ScreenContentView.releaseClosing`); a close taken back starts the pane's live frame from where it shows.
struct ClosingPanes {
    /// One edge of a closing pane, on its own spring.
    struct Edge {
        var spring: SpringValue
        /// The neighbour whose facing edge it rides (nil: it stays where it shows), and the gap it keeps to it.
        let neighbour: PaneID?
        let gap: CGFloat
    }

    struct Entry {
        var minX: Edge, maxX: Edge, minY: Edge, maxY: Edge
        /// It scrolls with the strip (not a docked pane), and the row column and scroll area it showed in.
        let scrolls: Bool
        let rowColumn: ColumnID?
        let area: SplitID?
        /// Where it showed (view x) before the change's camera moved (`ScreenContentView.settleCarried`); nil once placed.
        var carriedShown: CGFloat?

        var edges: [Edge] { [minX, maxX, minY, maxY] }
        /// Where it shows now (a pane past zero size shows nothing).
        var rect: CGRect {
            CGRect(x: minX.spring.value, y: minY.spring.value, width: max(0, maxX.spring.value - minX.spring.value),
                   height: max(0, maxY.spring.value - minY.spring.value))
        }
        var isMoving: Bool { edges.contains { $0.spring.value != $0.spring.target || $0.spring.velocity != 0 } }
        var nearRest: Bool { edges.allSatisfy { abs($0.spring.value - $0.spring.target) <= 0.25 && abs($0.spring.velocity) <= 2 } }

        /// Its frame as a live pane's spring rect (a close taken back springs on from here, with these velocities).
        var frame: AnimatedFrame {
            var frame = AnimatedFrame(rect)
            frame.x.velocity = minX.spring.velocity
            frame.width.velocity = maxX.spring.velocity - minX.spring.velocity
            frame.y.velocity = minY.spring.velocity
            frame.height.velocity = maxY.spring.velocity - minY.spring.velocity
            return frame
        }
    }

    private(set) var entries: [PaneID: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    /// Whether a closing pane still moves (it keeps the screen's frames ticking).
    var isMoving: Bool { entries.values.contains(where: \.isMoving) }
    /// Whether every closing pane is within a quarter point of where it rests (the screen lands them with the rest).
    var nearRest: Bool { entries.values.allSatisfy(\.nearRest) }

    /// Starts `pane` collapsing from `shown` (where it shows, in the new layout's coordinates). `before`: the layout it
    /// left (its neighbours and the gaps beside them); `frames`: every live pane's frame, its target the new layout's rest;
    /// `maxGap`: the widest gap between two neighbours (a column gap); `viewShift`: the strip's view shift in the new
    /// layout before the camera moves (what ``settleCarried(stripShift:)`` measures from), nil when nothing was carried.
    mutating func begin(_ pane: PaneID, shown: CGRect, before: ScreenGeometry, frames: [PaneID: AnimatedFrame], maxGap: CGFloat,
                        viewShift: CGFloat?) {
        guard let rest = before.panes[pane] else { return }
        /// The nearest neighbour across one side whose facing edge moves (one that rests where it is closes over nothing).
        var lead: (PaneID, CGFloat)?, trail: (PaneID, CGFloat)?, top: (PaneID, CGFloat)?, bottom: (PaneID, CGFloat)?
        func moves(_ frame: AnimatedFrame) -> Bool { frame.rect != frame.targetRect || frame.x.velocity != 0 || frame.width.velocity != 0 }
        for (other, was) in before.panes where other != pane {
            guard let live = frames[other], moves(live) else { continue }
            if min(was.maxY, rest.maxY) - max(was.minY, rest.minY) > 1 {
                let gapBefore = rest.minX - was.maxX, gapAfter = was.minX - rest.maxX
                if gapBefore >= -0.5, gapBefore <= maxGap, lead == nil { lead = (other, max(0, gapBefore)) }
                if gapAfter >= -0.5, gapAfter <= maxGap, trail == nil { trail = (other, max(0, gapAfter)) }
            }
            if min(was.maxX, rest.maxX) - max(was.minX, rest.minX) > 1 {
                let gapAbove = rest.minY - was.maxY, gapBelow = was.minY - rest.maxY
                if gapAbove >= -0.5, gapAbove <= maxGap, top == nil { top = (other, max(0, gapAbove)) }
                if gapBelow >= -0.5, gapBelow <= maxGap, bottom == nil { bottom = (other, max(0, gapBelow)) }
            }
        }
        /// An edge riding `side`'s facing edge (`high`: the neighbour's max edge), or staying at `value`.
        func edge(_ side: (PaneID, CGFloat)?, keepsGap: Bool, high: Bool, x: Bool, stays value: CGFloat) -> Edge {
            guard let side, let live = frames[side.0] else { return Edge(spring: SpringValue(value), neighbour: nil, gap: 0) }
            let gap = keepsGap ? side.1 : 0
            let (position, velocity) = x
                ? (high ? live.x.value + live.width.value : live.x.value, high ? live.x.velocity + live.width.velocity : live.x.velocity)
                : (high ? live.y.value + live.height.value : live.y.value, high ? live.y.velocity + live.height.velocity : live.y.velocity)
            var spring = SpringValue(position + (high ? gap : -gap))
            spring.velocity = velocity
            return Edge(spring: spring, neighbour: side.0, gap: gap)
        }
        let scrolls = before.scrolls(pane: pane)
        let minX = edge(lead, keepsGap: trail != nil, high: true, x: true, stays: shown.minX)
        var entry = Entry(minX: minX, maxX: edge(trail, keepsGap: false, high: false, x: true, stays: shown.maxX),
                          minY: edge(top, keepsGap: bottom != nil, high: true, x: false, stays: shown.minY),
                          maxY: edge(bottom, keepsGap: false, high: false, x: false, stays: shown.maxY),
                          scrolls: scrolls, rowColumn: before.rowColumnOfPane[pane], area: before.scrollAreaOfPane[pane],
                          carriedShown: viewShift.map { minX.spring.value + (scrolls ? $0 : 0) })
        Self.retarget(&entry, frames: frames)
        entries[pane] = entry
    }

    /// Each edge's rest from its neighbour's rest now (a change during the close moves it); an edge whose neighbour is at
    /// rest (it snapped: no animation) lands with it. A neighbour that went keeps the edge's last rest.
    mutating func retarget(frames: [PaneID: AnimatedFrame]) {
        for (pane, entry) in entries {
            var entry = entry
            Self.retarget(&entry, frames: frames)
            entries[pane] = entry
        }
    }

    private static func retarget(_ entry: inout Entry, frames: [PaneID: AnimatedFrame]) {
        func follow(_ edge: inout Edge, high: Bool, x: Bool) {
            guard let pane = edge.neighbour, let live = frames[pane] else { return }
            let target = live.targetRect
            let facing = x ? (high ? target.maxX : target.minX) : (high ? target.maxY : target.minY)
            edge.spring.target = facing + (high ? edge.gap : -edge.gap)
            if live.rect == live.targetRect, [live.x, live.y, live.width, live.height].allSatisfy({ $0.velocity == 0 }) { edge.spring.snap() }
        }
        follow(&entry.minX, high: true, x: true)
        follow(&entry.maxX, high: false, x: true)
        follow(&entry.minY, high: true, x: false)
        follow(&entry.maxY, high: false, x: false)
        // At rest a pane is never inside out: its far edge rests no nearer than its near one.
        if entry.maxX.spring.target < entry.minX.spring.target { entry.maxX.spring.target = entry.minX.spring.target }
        if entry.maxY.spring.target < entry.minY.spring.target { entry.maxY.spring.target = entry.minY.spring.target }
    }

    /// A new layout carried the strip (`drift`: the frames' x change, as `ScreenContentView.reconcile` moves the live
    /// ones); `viewShift`: the new layout's view shift, to place each again once the camera moved (nil: nothing carried).
    mutating func carry(drift: CGFloat, viewShift: CGFloat?) {
        for (pane, entry) in entries {
            var entry = entry
            if entry.scrolls, drift != 0 { Self.shiftX(&entry, by: drift) }
            entry.carriedShown = viewShift.map { entry.minX.spring.value + (entry.scrolls ? $0 : 0) }
            entries[pane] = entry
        }
    }

    /// The camera took its place for the new layout (`ScreenContentView.settleCarried`): each closing pane shows where it
    /// showed before the change (`shift`: the strip's view shift now).
    mutating func settleCarried(stripShift shift: CGFloat) {
        for (pane, entry) in entries {
            guard let shown = entry.carriedShown else { continue }
            var entry = entry
            Self.shiftX(&entry, by: shown - (entry.scrolls ? shift : 0) - entry.minX.spring.value)
            entry.carriedShown = nil
            entries[pane] = entry
        }
    }

    /// Moves a pane along x: an edge that stays moves its rest with it; one that rides a neighbour keeps the neighbour's.
    private static func shiftX(_ entry: inout Entry, by delta: CGFloat) {
        for keyPath in [\Entry.minX, \Entry.maxX] as [WritableKeyPath<Entry, Edge>] {
            entry[keyPath: keyPath].spring.value += delta
            if entry[keyPath: keyPath].neighbour == nil { entry[keyPath: keyPath].spring.target += delta }
        }
    }

    /// Steps every closing pane by `dt` on `spring` (the panes' close spring), unsettled as its neighbours are.
    mutating func step(_ dt: Double, spring: SpringParameters) { // perf-hot: 4ms motion-frame
        for (pane, entry) in entries {
            var entry = entry
            for keyPath in Self.edgePaths { entry[keyPath: keyPath].spring.step(dt, parameters: spring) }
            entries[pane] = entry
        }
    }

    private static let edgePaths: [WritableKeyPath<Entry, Edge>] = [\.minX, \.maxX, \.minY, \.maxY]

    /// Lands every closing pane where it rests, with its neighbours.
    mutating func snap() {
        for (pane, entry) in entries {
            var entry = entry
            for keyPath in Self.edgePaths { entry[keyPath: keyPath].spring.snap() }
            entries[pane] = entry
        }
    }

    /// Takes `pane` out (its close was taken back, or its host went): its frame now, to start its live frame from.
    mutating func remove(_ pane: PaneID) -> AnimatedFrame? { entries.removeValue(forKey: pane)?.frame }
}
