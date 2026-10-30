import AppKit
import CmuxNextDesign
import QuartzCore

// Scrolling: the unpinned tabs, chips and bands sit in the scrolling layer in content coordinates, and a
// scroll moves that layer's bounds (a wheel, a reveal's spring, a drag's autoscroll) and the +, never a tab's
// frame. Also where a layer shows now, with the scroll in flight, and the occlusion masks after a frame pass.
extension TabStripView {
    func reveal(_ id: TabID, animated: Bool) {
        guard let slot = slotIndex.slots[id] else { return }
        let target = TabScrollMath.offset(
            revealing: slot,
            current: scrollOffset,
            contentWidth: result.contentWidth,
            viewportWidth: viewportWidth,
            margin: metrics.scrollFadeWidth,
            fixedLeading: scrollMapping.band
        )
        // Already in view (a switch between shown tabs): the strip does not move.
        guard target != scrollOffset else { return }
        let from = scrollMapping
        scrollOffset = target
        var move: TabStripMove?
        if animated, !reduceMotion, Motion.canAnimate(in: self), let motion = MotionMove.spring(.scroll, in: Motion.tabs) {
            moveGeneration += 1
            move = TabStripMove(generation: moveGeneration, motion: motion, closing: nil, isScroll: true)
        }
        // A reveal only scrolls: with no motion the bounds move at once; its spring is the bounds' move.
        if let move { applyFrames(move: move, scrollFrom: from) } else { scrollChanged() }
    }

    /// A wheel or a drag's autoscroll takes the scroll over: the scroll part of every move still in
    /// flight (a reveal's spring, a relayout that keeps the selected tab in view) ends where it shows
    /// now (the scroll offset becomes that), so nothing drifts against the gesture; the rest of a
    /// relayout (tabs making room, a close) keeps moving.
    func settleScroll() {
        guard scrollProbe.animationKeys()?.isEmpty == false else { return }
        // What the scroll parts add now (a view x is the content x minus the offset): the probe takes only them.
        let shown = MotionPath(scrollProbe, "position").value(at: CACurrentMediaTime()).x
        scrollOffset = TabScrollMath.clamp(scrollOffset - (shown - scrollProbe.position.x), contentWidth: result.contentWidth,
                                           viewportWidth: viewportWidth)
        // The scroll moves the scrolling layer's bounds (every tab, chip and band in it) and the +, nothing else.
        var layers = [scrollProbe, scrollingLayer]
        layers += [newTabButton.layer, newTabMenuButton.layer].compactMap { $0 }
        TabStripMove.cancelScroll(on: layers)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyScrollBounds(scrollMapping)
        CATransaction.commit()
    }

    /// Where `id`'s cell shows now, its right edge in content coordinates (the presentation layer
    /// includes every move in flight); nil when it has no cell.
    func shownMaxX(_ id: TabID) -> CGFloat? {
        guard let layer = cells[id]?.layer ?? id.chipGroupID.flatMap({ groups.chips[$0]?.layer }) else { return nil }
        return scrollMapping.contentX(shownFrame(layer).maxX, isPinned: cells[id]?.item.isPinned ?? false)
    }

    /// Where `id`'s cell shows now, its left edge in content coordinates.
    func shownX(_ id: TabID) -> CGFloat? {
        guard let cell = cells[id] else { return nil }
        return scrollMapping.contentX(shownFrame(cell.layer).minX, isPinned: cell.item.isPinned)
    }

    /// Where a tab's, chip's or band's layer shows now in `tabsClip`'s coordinates: its presentation (every
    /// move in flight) in its layer, and the scroll in flight for a layer in the scrolling layer.
    func shownFrame(_ layer: CALayer) -> CGRect {
        let frame = (layer.presentation() ?? layer).frame
        guard layer.superlayer === scrollingLayer else { return frame }
        let origin = (scrollingLayer.presentation() ?? scrollingLayer).bounds.origin
        return frame.offsetBy(dx: scrollingLayer.frame.minX - origin.x, dy: scrollingLayer.frame.minY - origin.y)
    }

    /// The scrolling layer starts after the fixed band, and its bounds' x is the band plus the scroll offset
    /// (to the pixel), so a content x shows at the content x minus the offset. The only write a scroll makes
    /// to the layers that hold the tabs.
    func applyScrollBounds(_ mapping: TabScrollMapping) {
        let clip = tabsClip.bounds
        let frame = CGRect(x: mapping.band, y: clip.minY, width: max(0, clip.width - mapping.band), height: clip.height)
        if scrollingLayer.frame != frame { scrollingLayer.frame = frame }
        let origin = CGPoint(x: mapping.band + pixelOffset(mapping), y: clip.minY)
        if scrollingLayer.bounds.origin != origin { scrollingLayer.bounds.origin = origin }
    }

    /// The unpinned region's scroll offset to the device pixel: the scrolling layer's share of the bounds.
    func pixelOffset(_ mapping: TabScrollMapping) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (mapping.offset(isPinned: false) * scale).rounded() / scale
    }

    /// Moves `layer` into `parent` where it shows now (its position converted, before the scroll changes), so a
    /// move animates it on from there: a tab pinned or unpinned, or the fixed band coming or going.
    func reparent(_ layer: CALayer, to parent: CALayer) {
        let position = layer.superlayer.map { parent.convert(layer.position, from: $0) } ?? layer.position
        parent.addSublayer(layer)
        layer.position = position
    }

    /// The scroll changed and nothing else (a wheel): the scrolling layer's bounds take it, with the +, the
    /// edge fades, the tabs' accessibility frames and what is under a still pointer. No tab, chip or band frame
    /// and no mask is written: they sit in content coordinates (`applyFrames` for everything else).
    func scrollChanged() {
        rowPasses.scrolls &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mapping = scrollMapping
        applyScrollBounds(mapping)
        placeNewTabButton(mapping: mapping, move: nil, scroll: 0)
        for cell in cells.values { cell.accessibility.updateFrameInParentSpace(tabsClip.convert(cell.frame, to: self)) }
        for chip in groups.chips.values { chip.accessibility.updateFrameInParentSpace(tabsClip.convert(chip.frame, to: self)) }
        CATransaction.commit()
        edgeFade.update()
        geometryDidChange()
        if drag != nil || groups.drag != nil || phantomPoint != nil { startAnimating() }
    }

    /// The + after the last tab (`lastTrailing`, content coordinates), held at the strip's end. `scroll`: the
    /// view x the scroll alone moved it by in `move`.
    func placeNewTabButton(mapping: TabScrollMapping, move: TabStripMove?, scroll scrollPart: CGFloat) {
        let tabHeight = min(metrics.tabHeight, bounds.height)
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(lastTrailing - mapping.offset(isPinned: false), viewportWidth)
        // Square, centered on the tabs: it keeps its size when the tabs are shorter.
        let buttonFrame = CGRect(x: pixel(buttonX), y: pixel(tabTop + (tabHeight - buttonWidth) / 2), width: buttonWidth, height: buttonWidth)
        let buttonFrom = newTabButton.frame.origin
        if newTabButton.frame != buttonFrame { newTabButton.frame = buttonFrame }
        let menuFrame = CGRect(x: buttonFrame.maxX, y: buttonFrame.minY, width: newTabControlsWidth - buttonWidth, height: buttonFrame.height)
        if newTabMenuButton.frame != menuFrame { newTabMenuButton.frame = menuFrame }
        // The scroll moves it only where it follows the last tab both before and now (not held at the strip's end).
        let buttonEnd = pixel(tabsClip.frame.minX + viewportWidth) - 0.5
        let scroll = buttonFrame.minX < buttonEnd && buttonFrom.x < buttonEnd ? scrollPart : 0
        if let move, buttonFrom != buttonFrame.origin || abs(scroll) > 0.01 {
            // Both controls follow the same move and scroll, staying adjacent throughout the transition.
            let delta = CGPoint(x: buttonFrom.x - buttonFrame.minX - scroll, y: buttonFrom.y - buttonFrame.minY)
            for layer in [newTabButton.layer, newTabMenuButton.layer].compactMap({ $0 }) {
                if abs(delta.x) > 0.01 || abs(delta.y) > 0.01 {
                    move.add(move.motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: layer, as: "button")
                }
                move.addScroll(scroll, to: layer)
            }
        }
    }

    // MARK: - Occlusion

    /// Masks the tabs the selected pill covers now and along every move in flight (`TabOcclusion`).
    /// `settle`: a path that ends within it counts as ended.
    func updateOcclusion(settle: CFTimeInterval = 0.001) {
        rowPasses.occlusion &+= 1
        rowPasses.occlusionTabs &+= cells.count
        let selected = model.selectedID.flatMap { dying.contains($0) ? nil : $0 }
        occlusionEnds = TabOcclusion.update(cells: cells, selected: selected, band: scrollMapping.band, settle: settle)
        occlusionCover = selected.flatMap { cells[$0]?.layer.frame }
    }

    /// The masks after a frame pass, sampled along every path once per strip change (a pass that adds a move,
    /// a new generation). A pass that adds none (a drag step, a resize) re-cuts only the tabs whose mask can
    /// differ: the ones cut now, the ones under the selected pill, and the ones still moving; a pass that moved
    /// no tab and not the pill re-cuts none. A wheel runs no pass (`scrollChanged`).
    func occlusionAfterFrames(added move: TabStripMove?, wroteFrames: Bool) {
        let selected = model.selectedID.flatMap { dying.contains($0) ? nil : $0 }
        let cover = selected.flatMap { cells[$0]?.layer.frame }
        if move != nil { return updateOcclusion() }
        guard wroteFrames || cover != occlusionCover else { return }
        // No selected pill: the masks come off once, then nothing is cut.
        guard let cover else { return occlusionCover != nil || !occlusionEnds.isEmpty ? updateOcclusion() : () }
        let pill = TabOcclusion.pill(of: cover, height: cover.height, metrics: metrics)
        let candidates = Set(cells.compactMap { id, cell in
            cell.isOccluded || occlusionEnds[id] != nil || cell.layer.frame.intersects(pill) || TabStripMove.isMoving(cell.layer) ? id : nil
        })
        rowPasses.occlusionTabs &+= candidates.count
        let ends = TabOcclusion.update(cells: cells, selected: selected, band: scrollMapping.band, only: candidates)
        occlusionEnds = occlusionEnds.filter { !candidates.contains($0.key) }.merging(ends) { _, new in new }
        occlusionCover = cover
    }
}
