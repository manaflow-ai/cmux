import AppKit
import QuartzCore

/// What every cell's frame follows from besides its place (`TabStripView.cellFrame`), and where the tabs' clip sits in
/// the strip (the cells' accessibility frames).
struct TabCellFrameBasis: Equatable {
    var mapping: TabScrollMapping
    var tabTop: CGFloat
    var tabHeight: CGFloat
    var scale: CGFloat
    var clipOrigin: CGPoint
}

/// The cells' frames as the strip last wrote them: from `basis`, `count` cells, their trailing edge (the + follows it).
struct FramedCells: Equatable {
    var basis: TabCellFrameBasis
    var trailing: CGFloat
    var count: Int
}

// SMOOTH-STRIP (cmux-ad m18, RESIZE MAIN BUDGET STATUS 13566 item 3): a pane spring, a divider drag or a window resize
// changes the strip's width in each frame; the strip used to run the layout engine and write every cell then.
extension TabStripView {
    /// The basis of the cells' frames now, at `mapping`'s scroll.
    func cellFrameBasis(mapping: TabScrollMapping) -> TabCellFrameBasis {
        TabCellFrameBasis(mapping: mapping, tabTop: tabTop, tabHeight: min(metrics.tabHeight, bounds.height),
                          scale: window?.backingScaleFactor ?? 2, clipOrigin: tabsClip.frame.origin)
    }

    /// The strip's width changed and nothing else did. The slots follow from the row's share (`TabLayoutEngine.resized`:
    /// O(1) when no slot edge moves, else one walk; no layout engine run), and only the cells whose frames change are
    /// written: a width that moves no slot edge writes the scrolling layer and the + only. A strip with its own motion
    /// (a tab drag, a drop, a torn-out tab over it, a group drag, a close) takes the full relayout, as before.
    /// `narrower`: the strip scrolls to the selected tab (a split).
    func followWidth(narrower: Bool) { // perf-hot: 4ms motion-frame
        guard lastViewportWidth >= 0, drag == nil, groups.drag == nil, pendingDrop == nil, phantomPoint == nil, dropPlaceholderIndex == nil,
              dying.isEmpty
        else { return relayout(animated: false, keepsSelectedInView: narrower, keepsClosing: true) }
        let resized = TabLayoutEngine.resized(result, availableWidth: viewportWidth, style: model.style, metrics: metrics,
                                              closingModeWidth: closingModeWidth)
        let slotsMoved = resized.slots != result.slots
        let index = slotIndexCache
        result = resized
        if slotsMoved {
            for slot in result.slots {
                guard var place = placed[slot.id] else { continue }
                place.x = slot.x
                place.width = slot.width
                place.alpha = slot.isCollapsed ? 0 : 1
                placed[slot.id] = place
            }
        } else {
            // The same slots: the index of the last layout still holds.
            slotIndexCache = index
        }
        updateCrowded()
        scrollOffset = TabScrollMath.clamp(scrollOffset, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        if narrower, let slot = model.selectedID.flatMap({ slotIndex.slots[$0] }) {
            scrollOffset = TabScrollMath.offset(revealing: slot, current: scrollOffset, contentWidth: result.contentWidth, viewportWidth: viewportWidth,
                                                margin: metrics.scrollFadeWidth, fixedLeading: scrollMapping.band)
        }
        writeFollowedFrames(slotsMoved: slotsMoved)
    }

    /// `applyFrames` with no move, writing only what changed: the cells, chips, bands and pinned divider only when a slot
    /// or their basis (the scroll, the row's height, the pixel grid) changed, and then only the cells whose frames differ.
    private func writeFollowedFrames(slotsMoved: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let mapping = scrollMapping
        let clip = tabsClip.bounds
        scrollingLayer.frame = CGRect(x: mapping.band, y: clip.minY, width: max(0, clip.width - mapping.band), height: clip.height)
        scrollingLayer.bounds.origin = CGPoint(x: mapping.band, y: clip.minY)
        let basis = cellFrameBasis(mapping: mapping)
        func pixel(_ value: CGFloat) -> CGFloat { (value * basis.scale).rounded() / basis.scale }
        var moved = false
        var trailing: CGFloat
        if let framed = framedCells, !slotsMoved, framed.basis == basis, framed.count == cells.count {
            trailing = framed.trailing
        } else {
            let clipMoved = framedCells?.basis.clipOrigin != basis.clipOrigin
            trailing = 0
            for (id, cell) in cells {
                guard let place = placed[id] else { continue }
                let frame = cellFrame(place, isPinned: cell.item.isPinned, mapping: mapping)
                let opacity = Float(min(max(place.alpha, 0), 1))
                let changed = frame != cell.frame
                if changed {
                    cell.frame = frame
                    moved = true
                }
                if opacity != cell.layer.opacity { cell.layer.opacity = opacity }
                if changed || clipMoved { cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self)) }
                trailing = max(trailing, place.maxX)
            }
            updateOcclusion()
            layoutPinnedDivider(mapping: mapping, tabY: basis.tabTop, tabHeight: basis.tabHeight, pixel: pixel)
            for group in groups.chips.keys {
                guard let place = placed[.groupChip(group)] else { continue }
                trailing = max(trailing, place.maxX)
            }
            if !groups.chips.isEmpty {
                applyGroupFrames(offset: mapping.offset(isPinned: false), tabY: basis.tabTop, tabHeight: basis.tabHeight, pixel: pixel)
            }
            framedCells = FramedCells(basis: basis, trailing: trailing, count: cells.count)
        }
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - mapping.offset(isPinned: false), viewportWidth)
        let buttonFrame = CGRect(x: pixel(buttonX), y: pixel(basis.tabTop + (basis.tabHeight - buttonWidth) / 2), width: buttonWidth, height: buttonWidth)
        let menuFrame = CGRect(x: buttonFrame.maxX, y: buttonFrame.minY, width: newTabControlsWidth - buttonWidth, height: buttonFrame.height)
        if newTabButton.frame != buttonFrame {
            newTabButton.frame = buttonFrame
            moved = true
        }
        if newTabMenuButton.frame != menuFrame { newTabMenuButton.frame = menuFrame }
        edgeFade.update()
        // What is under a still pointer changed only where something moved.
        if moved { geometryDidChange() }
    }
}
