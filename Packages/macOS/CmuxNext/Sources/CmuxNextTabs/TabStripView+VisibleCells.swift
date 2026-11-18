import AppKit
import CmuxNextDesign
import QuartzCore
public import CmuxVisibleRows

// Visible-only tabs (Leo 2026-11-18: "we draw the visible area, right?"). A tab has a cell (its layers and its
// accessibility element) only while its slot lies within one viewport of what the strip shows, or while something
// holds it (``heldIDs``: selected, under the pointer, pressed, dragged, closing, renamed); a cell still moving stays
// until its move ends. A scroll step makes the cells it reveals and drops the ones it leaves behind, so what it costs
// follows the viewport, not the tab count. Every tab keeps its id (`tabIDs`) and its place (`placed`).
extension TabStripView {
    /// The width one viewport of overscan is: the tabs' clip, or the strip's own before its first layout.
    private var mountViewportWidth: CGFloat { viewportWidth > 0 ? viewportWidth : bounds.width }

    /// The content x range of unpinned (or scrolling pinned) tabs within one viewport each side of the view at `offset`.
    private func mountSpan(offset: CGFloat) -> ClosedRange<Double> {
        VisibleWindow.span(offset: Double(offset), length: Double(mountViewportWidth))
    }

    /// Whether `slot` gets a cell at `offset`: inside the span, or a pinned tab in the fixed band (always shown).
    func isInMountRange(_ slot: TabLayoutSlot, offset: CGFloat, band: CGFloat) -> Bool {
        if slot.isPinned, band > 0 { return true }
        let span = mountSpan(offset: offset)
        return Double(slot.maxX) >= span.lowerBound && Double(slot.x) <= span.upperBound
    }

    /// The slots that get a cell at `offset`, by index in `result.slots`: the fixed pinned band and the span
    /// (`VisibleWindow`, binary search: the slots run left to right, each starting where the one before ends, or after).
    func mountRanges(offset: CGFloat, band: CGFloat) -> [Range<Int>] {
        let slots = result.slots
        let span = VisibleWindow.mounted(count: slots.count, offset: Double(offset), length: Double(mountViewportWidth),
                                         start: { Double(slots[$0].x) }, end: { Double(slots[$0].maxX) })
        let pinnedEnd = band > 0 ? min(span.lowerBound, VisibleWindow.partition(slots.count) { !slots[$0].isPinned }) : 0
        return pinnedEnd > 0 ? [0..<pinnedEnd, span] : [span]
    }

    /// Tabs that keep their cell wherever they are: what the pointer, a press, a drag, a close, a rename or the
    /// selection is on.
    var heldIDs: Set<TabID> {
        var held = dying
        for id in [model.selectedID, hoveredID, closeHoveredID, pressedCloseID, pressedAudioID, audioHoveredID, middlePressID, press?.id,
                   drag?.id, pendingDrop?.id, inlineRename.editingID] {
            if let id { held.insert(id) }
        }
        return held
    }

    /// Makes the cells of the tabs in the mounted range and the held ones that have none, showing them at `mapping`'s
    /// scroll (where the other layers show now; a move then takes them on with the rest). Walks the range only.
    func mountVisibleCells(showing mapping: TabScrollMapping? = nil) {
        let shown = mapping ?? scrollMapping
        let band = scrollMapping.band
        var made: [TabID] = []
        for range in mountRanges(offset: scrollOffset, band: band) {
            for index in range {
                let id = result.slots[index].id
                if cells[id] == nil, mountCell(id, showing: shown) != nil { made.append(id) }
            }
        }
        for id in heldIDs where cells[id] == nil {
            if mountCell(id, showing: shown) != nil { made.append(id) }
        }
        // Their own lines; the others keep theirs.
        if !made.isEmpty { TabSeparatorVisibility.apply(to: self, around: made) }
    }

    /// Drops the cells of tabs out of the mounted range that nothing holds and that no move carries. `shownFrom`: a move
    /// is about to start from that scroll; a cell it would show there (in view, not only in range) stays for it.
    func dropHiddenCells(shownFrom: TabScrollMapping? = nil) {
        guard !cells.isEmpty else { return }
        let held = heldIDs
        let band = scrollMapping.band
        let slots = slotIndex.slots
        let width = mountViewportWidth
        var dropping: [TabID] = []
        for (id, cell) in cells where !held.contains(id) {
            guard let slot = slots[id], !isInMountRange(slot, offset: scrollOffset, band: band),
                  cell.layer.animationKeys()?.isEmpty != false else { continue }
            if let from = shownFrom, slot.maxX >= from.offset, slot.x <= from.offset + width { continue }
            dropping.append(id)
        }
        for id in dropping { unmountCell(id) }
    }

    /// Makes tab `id`'s cell, at its place at `mapping`'s scroll, with the strip's state for it. Nil when the strip
    /// does not show the tab or it has a cell already.
    @discardableResult
    func mountCell(_ id: TabID, showing mapping: TabScrollMapping? = nil) -> TabCell? {
        guard cells[id] == nil, id.chipGroupID == nil, tabIDs.contains(id), let index = displayedIndex[id], displayed.indices.contains(index),
              displayed[index].id == id, let place = placed[id] else { return nil }
        let item = displayed[index]
        let cell = makeCellLayers(item)
        cell.isSelected = id == model.selectedID
        cell.showsZoom = model.zoomsSelected && id == model.selectedID
        cell.isMultiSelected = model.multiSelection.contains(id)
        cell.isLifted = drag?.id == id || groups.isDragged(id)
        cell.frame = cellFrame(place, isPinned: item.isPinned, mapping: mapping ?? scrollMapping)
        cell.layer.opacity = Float(min(max(place.alpha, 0), 1))
        cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self))
        framedCells = nil
        listWork.configured()
        listWork.laidOut()
        return cell
    }

    /// Drops tab `id`'s cell; the tab keeps its place. An accessibility client keeps the element it may hold.
    func unmountCell(_ id: TabID) {
        guard let cell = cells.removeValue(forKey: id) else { return }
        cell.layer.removeFromSuperlayer()
        if servesAccessibility {
            parkedAccessibility[id] = cell.accessibility
        } else {
            noteAccessibilityFocus(ObjectIdentifier(cell.accessibility), false)
        }
        occlusionEnds[id] = nil
        framedCells = nil
    }

    /// The trailing edge of the tabs with no cell (the + follows the last tab): their places are their slots.
    func unmountedTrailing() -> CGFloat {
        guard cells.count < tabIDs.count else { return 0 }
        guard let last = result.slots.last(where: { $0.id != Self.placeholderID && $0.id.chipGroupID == nil && cells[$0.id] == nil }) else { return 0 }
        return placed[last.id]?.maxX ?? last.maxX
    }

    /// Tab `slot`'s element while it has no cell: what VoiceOver reads and presses there, at its place.
    func parkedAccessibility(for slot: TabLayoutSlot) -> TabAccessibilityElement? {
        guard let index = displayedIndex[slot.id], displayed.indices.contains(index), displayed[index].id == slot.id else { return nil }
        let item = displayed[index]
        let id = item.id
        let element: TabAccessibilityElement
        if let parked = parkedAccessibility[id] {
            element = parked
        } else {
            element = TabAccessibilityElement()
            element.setAccessibilityParent(self)
            element.onPress = { [weak self] in self?.model.send(.select(id)) }
            element.onClose = { [weak self] in self?.close(id, source: .accessibility) }
            let identity = ObjectIdentifier(element)
            element.onFocus = { [weak self] focused in self?.noteAccessibilityFocus(identity, focused) }
            parkedAccessibility[id] = element
        }
        element.setAccessibilityLabel(TabCell.accessibilityLabel(item, showsZoom: false))
        element.setAccessibilityIdentifier("cmux.tabs.tab.\(id.rawValue)")
        element.setAccessibilityValue(id == model.selectedID ? 1 : 0)
        element.setAccessibilityHelp(TabCell.accessibilityHelp(item))
        element.closeButton.setAccessibilityLabel(Strings.axClose)
        element.closeButton.setAccessibilityIdentifier("cmux.tabs.tab.\(id.rawValue).close")
        if let audio = item.audio {
            let mute: @MainActor () -> Void = { [weak self] in self?.model.send(.toggleAudioMute(id)) }
            element.badgeActions = [(name: audio == .muted ? Strings.unmuteTab : Strings.muteTab, run: mute)]
        } else {
            element.badgeActions = []
        }
        let place = placed[id] ?? TabPlace(x: slot.x, width: slot.width)
        let frame = cellFrame(place, isPinned: item.isPinned)
        element.setAccessibilityFrameInParentSpace(tabsClip.convert(frame, to: self))
        // Its x, pressable where it shows on hover (the pill's trailing end), as a cell's is; none on a pinned tab.
        let side = metrics.closeButtonSize
        let closes = item.isClosable && !item.isPinned && frame.width > side * 2
        element.closeButton.setAccessibilityFrameInParentSpace(closes
            ? CGRect(x: frame.width - side - metrics.contentLeadingInset, y: (frame.height - side) / 2, width: side, height: side) : .zero)
        return element
    }
}

/// The strip under the visible-rows contract: its rows are its cells (one layer tree and element each), made only for
/// the tabs in view and the held ones.
extension TabStripView: VisibleRowsList {
    public var rowViewsAlive: Int { cells.count }
}
