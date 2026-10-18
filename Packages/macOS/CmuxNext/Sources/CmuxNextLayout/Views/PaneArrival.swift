import CmuxNextDesign
import CoreGraphics

/// Where a pane added by a split starts (cx-f6i7): a zero-width (or
/// zero-height) sliver at the far edge of the space it takes from the pane
/// it split, so the pane grows in from that edge while the split pane
/// shrinks on the same spring and the divider between them slides from the
/// edge to its place. Nothing overlaps and no gap opens.
struct PaneArrival: Equatable {
    /// The new pane's first frame.
    var seed: CGRect
    /// How far the shared edge (and the divider on it) starts from its target.
    var edgeOffset: CGVector

    /// The arrival of a pane whose frame will be `target`, given every pane's
    /// frame before (`previous`) and after (`next`) the change; nil when no
    /// existing pane gave up the space (a strip column appended, a pane moved
    /// in from elsewhere), which then lands in place.
    static func of(target: CGRect, previous: [PaneID: CGRect], next: [PaneID: CGRect]) -> PaneArrival? {
        let slack: CGFloat = 1
        for (pane, before) in previous {
            // The pane that gave up the space shrank inside its old frame (a
            // column inserted mid-strip pushes its neighbor along instead).
            guard let after = next[pane], before.insetBy(dx: -slack, dy: -slack).contains(target),
                  before.insetBy(dx: -slack, dy: -slack).contains(after), after.width * after.height < before.width * before.height - 1 else { continue }
            if target.minX >= after.maxX - slack {
                // Split right: the new pane comes in from the old right edge.
                return PaneArrival(seed: CGRect(x: target.maxX, y: target.minY, width: 0, height: target.height),
                                   edgeOffset: CGVector(dx: target.width, dy: 0))
            }
            if target.maxX <= after.minX + slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: 0, height: target.height),
                                   edgeOffset: CGVector(dx: -target.width, dy: 0))
            }
            if target.minY >= after.maxY - slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.maxY, width: target.width, height: 0),
                                   edgeOffset: CGVector(dx: 0, dy: target.height))
            }
            if target.maxY <= after.minY + slack {
                return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: target.width, height: 0),
                                   edgeOffset: CGVector(dx: 0, dy: -target.height))
            }
        }
        return nil
    }

    /// The arrivals of a split or a new dock column: exactly one new pane,
    /// nothing removed, and an existing pane gave up its space. Empty
    /// otherwise. Compared where the panes show (strip panes shift with the
    /// scroll `offset` and the strip's origin, which a dock moves); the seed
    /// is in the new pane's own coordinates.
    static func split(_ previous: [PaneID: CGRect], from old: ScreenGeometry, to new: ScreenGeometry,
                      offset: CGFloat) -> [PaneID: PaneArrival] {
        let before = shown(previous, in: old, offset: offset), after = shown(new.panes, in: new, offset: offset)
        let added = after.keys.filter { before[$0] == nil }
        guard added.count == 1, before.keys.allSatisfy({ after[$0] != nil }), let pane = added.first, let target = after[pane],
              var arrival = of(target: target, previous: before, next: after) ?? docking(pane, target: target, from: old, to: new)
        else { return [:] }
        // A split should be one synchronized reposition: the existing pane and
        // divider travel on the move spring while the new pane is already at
        // its final geometry and fades in. Seeding the new pane as a zero-size
        // sliver makes the content resize after the reflow, which reads as a
        // second animation and leaves a visible lag behind Cmd-D.
        arrival.seed = target
        if new.scrolls(pane: pane) { arrival.seed.origin.x -= new.viewShift(offset: offset) }
        return [pane: arrival]
    }

    /// Panes only went away: a close (an unsplit, a strip column closed
    /// mid-strip), a zoom (the screen shows its zoomed pane alone) or a pane
    /// moved to another screen. Each pane left springs from where it showed to
    /// its place, keyed by its id, so it grows over the space or slides along
    /// the strip instead of jumping.
    static func departing(_ previous: some Collection<PaneID>, to next: some Collection<PaneID>) -> Bool {
        let before = Set(previous)
        return !next.isEmpty && next.count < before.count && next.allSatisfy { before.contains($0) }
    }

    /// A pane opening a new docked column where no one pane gave up the
    /// space (the strip reflows its columns around it): it grows in from the
    /// screen edge the column docks to, and the strip springs aside with it.
    /// Overlay columns float on glass that does not grow, so they land in place.
    static func docking(_ pane: PaneID, target: CGRect, from old: ScreenGeometry, to new: ScreenGeometry) -> PaneArrival? {
        // Only a column the new pane opens alone: a pane moved in beside it would fly in unlinked.
        guard let entry = new.dockFrame(containing: pane), entry.dock.mode != .overlay,
              !old.dock.contains(where: { $0.column == entry.column }),
              new.fixedPanes.allSatisfy({ $0 == pane || new.dockFrame(containing: $0)?.column != entry.column }) else { return nil }
        if target.maxX <= new.clipMinX + 1 {
            return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: 0, height: target.height),
                               edgeOffset: CGVector(dx: -target.width, dy: 0))
        }
        if target.minX >= new.clipMaxX - 1 {
            return PaneArrival(seed: CGRect(x: target.maxX, y: target.minY, width: 0, height: target.height),
                               edgeOffset: CGVector(dx: target.width, dy: 0))
        }
        if target.maxY <= new.clipMinY + 1 {
            return PaneArrival(seed: CGRect(x: target.minX, y: target.minY, width: target.width, height: 0),
                               edgeOffset: CGVector(dx: 0, dy: -target.height))
        }
        if target.minY >= new.clipMaxY - 1 {
            return PaneArrival(seed: CGRect(x: target.minX, y: target.maxY, width: target.width, height: 0),
                               edgeOffset: CGVector(dx: 0, dy: target.height))
        }
        return nil
    }

    private static func shown(_ rects: [PaneID: CGRect], in geometry: ScreenGeometry, offset: CGFloat) -> [PaneID: CGRect] {
        let shift = geometry.viewShift(offset: offset)
        return Dictionary(uniqueKeysWithValues: rects.map { pane, rect in
            (pane, geometry.scrolls(pane: pane) ? rect.offsetBy(dx: shift, dy: 0) : rect)
        })
    }

    /// Where an arriving pane's host sits while its frame springs from the
    /// seed: at its target size (one terminal resize, not one per frame),
    /// moved with the edge that moves, so its content slides in from there.
    static func presentation(shown: CGRect, target: CGRect) -> CGRect {
        target.offsetBy(dx: (shown.minX - target.minX) + (shown.maxX - target.maxX),
                        dy: (shown.minY - target.minY) + (shown.maxY - target.maxY))
    }

    /// The range strip panes show in beside docked columns (nil without
    /// any), moved with docks still growing in from their edge (`docks`, the
    /// arriving frames), so the strip is never cut short of a dock that has
    /// not reached its place.
    static func stripClip(_ geometry: ScreenGeometry, docks: [AnimatedFrame]) -> CGRect? {
        guard !geometry.dock.isEmpty else { return nil }
        var minX = geometry.clipMinX, maxX = geometry.clipMaxX, minY = geometry.clipMinY, maxY = geometry.clipMaxY
        for dock in docks {
            let shown = dock.rect, target = dock.targetRect
            if target.maxX <= geometry.clipMinX + 1 { minX += shown.maxX - target.maxX }
            if target.minX >= geometry.clipMaxX - 1 { maxX += shown.minX - target.minX }
            if target.maxY <= geometry.clipMinY + 1 { minY += shown.maxY - target.maxY }
            if target.minY >= geometry.clipMaxY - 1 { maxY += shown.minY - target.minY }
        }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The dock columns a structural change added, when it grows a pane in;
    /// only their panes move the strip's clip and covers (a split inside a
    /// dock that was there does not).
    static func newDocks(_ arrivals: [PaneID: PaneArrival], from old: ScreenGeometry, to new: ScreenGeometry) -> Set<ColumnID> {
        arrivals.isEmpty ? [] : Set(new.dock.map(\.column)).subtracting(old.dock.map(\.column))
    }

    /// The frames that move the strip's clip and covers while a new dock column (`docks`) grows
    /// in: one per docked column, the new columns' arriving pane and any dock still springing to
    /// its new size (a second dock shrinks the first, both sharing the width), so the strip never
    /// shows past a dock's moving edge.
    static func growing(_ arriving: Set<PaneID>, frames: [PaneID: AnimatedFrame], in geometry: ScreenGeometry,
                        docks: Set<ColumnID>) -> [AnimatedFrame] {
        guard geometry.dock.contains(where: { docks.contains($0.column) }) else { return [] }
        var moving: [ColumnID: AnimatedFrame] = [:]
        for pane in geometry.fixedPanes {
            guard let frame = frames[pane], let column = geometry.dockFrame(containing: pane)?.column, moving[column] == nil else { continue }
            if docks.contains(column) ? arriving.contains(pane) : frame.rect != frame.targetRect { moving[column] = frame }
        }
        return Array(moving.values)
    }

    /// What each docked column hides of the strip, its inner edge moved with
    /// a dock still growing in (`docks`, the arriving frames), so strip rings
    /// are not cut at the edge the dock has yet to reach.
    static func covers(_ geometry: ScreenGeometry, docks: [AnimatedFrame]) -> [CGRect] {
        geometry.dock.map { entry in
            var cover = entry.cover
            for dock in docks where dock.targetRect.intersects(entry.cover) {
                let shown = dock.rect, target = dock.targetRect
                if target.maxX <= geometry.clipMinX + 1 {
                    cover.size.width = max(0, cover.width + shown.maxX - target.maxX)
                } else if target.minX >= geometry.clipMaxX - 1 {
                    let moved = min(shown.minX - target.minX, cover.width)
                    cover = CGRect(x: cover.minX + moved, y: cover.minY, width: cover.width - moved, height: cover.height)
                } else if target.maxY <= geometry.clipMinY + 1 {
                    cover.size.height = max(0, cover.height + shown.maxY - target.maxY)
                } else if target.minY >= geometry.clipMaxY - 1 {
                    let moved = min(shown.minY - target.minY, cover.height)
                    cover = CGRect(x: cover.minX, y: cover.minY + moved, width: cover.width, height: cover.height - moved)
                }
            }
            return cover
        }
    }
}
