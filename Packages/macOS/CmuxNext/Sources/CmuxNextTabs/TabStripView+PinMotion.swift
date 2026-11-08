import AppKit
import CmuxNextDesign
import QuartzCore

// Pin and unpin (Lawrence 2026-11-08, cmux-ad m70: "animation when i pin stuff and unpin stuff is not very good. like
// it needs to translate properly from its original position to new position"). Chromium moves the same tab view to its
// new slot (`TabStripLayoutHelper` + `BoundsAnimator`); so does the strip: the cell is never replaced, and the strip's
// one tween takes it from where it shows to its slot while its neighbours slide (`applyFrames`). Three things differ
// from a plain reorder because a pinned tab lives in another layer than the unpinned ones:
// - The cell flies in the tabs' own layer, above both regions, and only joins its region's layer when every move
//   ended: the unpinned tabs' layer clips at the pinned band's edge, which jumps to its new place in the change.
// - While a flight runs with no scroll, that layer does not clip at all, so a neighbour that slides out from under the
//   band's new edge is never cut (with a scroll it clips, as before).
// - The pinned divider never slides through the flying tab: it fades out where it was (pushed along by a tab growing
//   into it) and fades in at its new place once no flying tab covers it (`layoutPinnedDivider`).
// The look (the title hides and the icon centres, or back) changes on the width's progress (`TabCell.retimePin`).
extension TabStripView {
    /// Before `applyFrames` writes the cells: with `move`, each tab whose region changed starts a flight. Returns the
    /// flying cells' layers (the divider keeps out of them).
    func flyPinnedTabs(move: TabStripMove?, mapping: TabScrollMapping, scrollFrom: TabScrollMapping?) -> [CALayer] {
        guard move != nil, let tabs = tabsClip.layer else {
            // A change at once while a flight still moves (a wheel, a resize) keeps it flying; a scroll clips again.
            if movesInFlight.isEmpty { landPinFlights() } else if mapping.offset(isPinned: false) != 0 { scrollingLayer.masksToBounds = true }
            return []
        }
        for (id, cell) in cells {
            guard let parent = tabsLayer(isPinned: cell.item.isPinned), let current = cell.layer.superlayer, current !== parent,
                  !pinFlights.contains(id) else { continue }
            if current !== tabs { tabs.addSublayer(cell.layer) }
            cell.layer.zPosition = 1
            pinFlights.insert(id)
        }
        let still = mapping.offset(isPinned: false) == 0 && (scrollFrom?.offset(isPinned: false) ?? 0) == 0
        scrollingLayer.masksToBounds = pinFlights.isEmpty || !still
        return pinFlights.compactMap { cells[$0]?.layer }
    }

    /// Every move ended (or a change applies at once): each flying tab joins its region's layer and the band clips again.
    func landPinFlights() {
        guard !pinFlights.isEmpty || !scrollingLayer.masksToBounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in pinFlights {
            guard let cell = cells[id] else { continue }
            cell.layer.zPosition = 0
            if let parent = tabsLayer(isPinned: cell.item.isPinned), cell.layer.superlayer !== parent { parent.addSublayer(cell.layer) }
        }
        pinFlights = []
        scrollingLayer.masksToBounds = true
        CATransaction.commit()
    }

    /// The divider's path when tabs fly across the pinned group's end: from `oldX` it fades out on the first half of
    /// the move (sooner if a flying tab reaches it; a tab that grows into it from the left pushes it along), and at
    /// `newX` it fades in once no flying tab covers that place. Opacity and x per 120 Hz sample, as keyframes.
    func addPinnedDividerCrossing(_ move: TabStripMove, from oldX: CGFloat, wasShown: Bool, crossing: [CALayer]) {
        let divider = pinnedDivider
        let newX = divider.position.x
        let duration = move.duration(closing: false)
        let count = MotionPath.sampleCount(seconds: duration)
        let times = MotionPath.times(from: move.begin, to: move.begin + duration, count: count)
        let paths = crossing.map { ($0, MotionPath($0, "position", now: move.begin), MotionPath($0, "bounds.size", now: move.begin)) }
        let frames: [[CGRect]] = times.map { time in
            paths.map { layer, position, size in
                let p = position.value(at: time), s = size.value(at: time)
                return CGRect(x: p.x - layer.anchorPoint.x * s.x, y: 0, width: s.x, height: s.y)
            }
        }
        func covers(_ x: CGFloat, _ frame: CGRect) -> Bool { x > frame.minX - 0.5 && x < frame.maxX + 0.5 }
        let last = times.count - 1
        // Out: by half the move, or the sample before a tab from its right reaches it (at least two samples).
        var outEnd = wasShown ? max(2, last / 2) : 0
        if wasShown, let reached = frames.indices.dropFirst().first(where: { k in
            frames[k].indices.contains { index in covers(oldX, frames[k][index]) && frames[0][index].minX >= oldX }
        }) { outEnd = max(2, min(outEnd, reached - 1)) }
        // In: a tab that lands left of the new place carries it on its trailing edge (the pinned group's end), so it
        // never draws inside that tab; it shows after the last sample a flying tab covers it (at least three before the end).
        let ends = frames[last]
        let inXs = times.indices.map { k in
            frames[k].indices.reduce(newX) { x, index in
                ends[index].maxX <= newX ? max(x, frames[k][index].maxX + (newX - ends[index].maxX)) : x
            }
        }
        let coveredLast = frames.indices.last { k in frames[k].contains { covers(inXs[k], $0) } } ?? -1
        let inStart = min(max(outEnd, coveredLast + 1), max(outEnd, last - 3))
        var xs: [CGFloat] = [], opacities: [Float] = []
        for k in times.indices {
            if k <= outEnd, wasShown {
                // A tab left of it at the start that grows into it pushes it along its trailing edge.
                var x = oldX
                for (index, start) in frames[0].enumerated() where start.maxX <= oldX {
                    x = max(x, frames[k][index].maxX + (oldX - start.maxX))
                }
                xs.append(x)
                opacities.append(Float(1 - CGFloat(k) / CGFloat(max(1, outEnd))))
            } else {
                xs.append(inXs[k])
                opacities.append(k <= inStart ? 0 : Float(CGFloat(k - inStart) / CGFloat(max(1, last - inStart))))
            }
        }
        let y = divider.position.y
        if let position = MotionPath.keyframes("position", values: xs.map { NSValue(point: CGPoint(x: $0, y: y)) }, times: times, on: divider) {
            move.add(position, to: divider, as: "divider.crossing.position")
        }
        if let fade = MotionPath.keyframes("opacity", values: opacities.map { NSNumber(value: $0) }, times: times, on: divider) {
            move.add(fade, to: divider, as: "divider.crossing.opacity")
        }
    }
}
