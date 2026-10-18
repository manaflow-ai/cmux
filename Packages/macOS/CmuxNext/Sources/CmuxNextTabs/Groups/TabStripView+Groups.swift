public import AppKit
import CmuxNextDesign
import QuartzCore

// Group chips and bands: sync, frames, hit testing, hover, editor.
extension TabStripView {
    // MARK: - Chip sync

    /// Creates, updates, and retires chips for the groups present in
    /// `ordered`. Returns the chip layout ids that were added.
    func syncChips(_ ordered: [TabItem], animated: Bool) -> Set<TabID> {
        var counts: [TabGroupID: Int] = [:]
        for tab in ordered { if let group = tab.groupID, groups.byID[group] != nil { counts[group, default: 0] += 1 } }
        var added: Set<TabID> = []
        for (group, chip) in groups.chips where counts[group] == nil {
            let id = TabID.groupChip(group)
            guard !dying.contains(id) else { continue }
            if animated {
                dying.insert(id)
                placed[id]?.width = 0
                placed[id]?.alpha = 0
                chip.isHovered = false
            } else {
                removeChip(group)
            }
        }
        for (group, count) in counts {
            guard let item = groups.byID[group] else { continue }
            let id = TabID.groupChip(group)
            if let chip = groups.chips[group] {
                dying.remove(id)
                goesAt[id] = nil
                chip.update(group: item, memberCount: count)
                groups.bands[group]?.color = item.tint
                continue
            }
            let chip = TabGroupChipCell(group: item, memberCount: count)
            chip.metrics = metrics
            chip.font = Typography.caption
            chip.themeScope = themeScope
            chip.scale = window?.backingScaleFactor ?? 2
            chip.accessibility.setAccessibilityParent(self)
            chip.accessibility.onPress = { [weak self] in self?.model.send(.toggleGroupCollapsed(group)) }
            let band = TabGroupBandCell(color: item.tint)
            band.themeScope = themeScope
            band.addTo(scrollingLayer)
            scrollingLayer.addSublayer(chip.layer)
            groups.chips[group] = chip
            groups.bands[group] = band
            // Placed by `relayout`.
            placed[id] = TabPlace(x: 0, width: 0)
            added.insert(id)
        }
        return added
    }

    func removeChip(_ group: TabGroupID) {
        let id = TabID.groupChip(group)
        groups.chips[group]?.layer.removeFromSuperlayer()
        groups.chips[group] = nil
        groups.bands[group]?.remove()
        groups.bands[group] = nil
        forgetPlace(id)
        if groups.hoveredChip == group { groups.hoveredChip = nil }
    }

    // MARK: - Frames

    /// Positions chips and bands at their places; with `move`, each one that moved animates there.
    /// `offset`: the unpinned region's (`TabScrollMapping.offset(isPinned: false)`); chips are never pinned.
    func applyGroupFrames(offset: CGFloat, tabY: CGFloat, tabHeight: CGFloat, pixel: (CGFloat) -> CGFloat, move: TabStripMove? = nil) {
        var memberMaxX: [TabGroupID: CGFloat] = [:]
        for item in displayed {
            guard let group = item.groupID, let place = placed[item.id] else { continue }
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, place.maxX)
        }
        if let drag, let group = drag.targetGroup, let place = placed[drag.id] {
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, place.maxX)
        }
        if let placeholder = result.slot(Self.placeholderID), let group = placeholder.groupID {
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, placeholder.maxX)
        }
        for (group, chip) in groups.chips {
            let id = TabID.groupChip(group)
            guard let place = placed[id] else { continue }
            let width = max(0, place.width)
            let minX = pixel(place.x - offset)
            let frame = CGRect(x: minX, y: tabY, width: pixel(place.x - offset + width) - minX, height: tabHeight)
            let alpha = Float(min(max(place.alpha, 0), 1))
            let direct = groups.isDragged(id)
            var moved = false
            if let move, frame != chip.frame || alpha != chip.layer.opacity {
                let before = TabStripMove.snapshot(chip.layer)
                chip.frame = frame
                chip.layer.opacity = alpha
                moved = move.animate(from: before)
            } else {
                chip.frame = frame
                chip.layer.opacity = alpha
            }
            if direct { TabStripMove.cancelPosition(chip.layer) }
            if let move { noteClosing(id, moved: moved, move: move) }
            chip.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(chip.frame, to: self))
            guard let band = groups.bands[group] else { continue }
            let pillMinX = place.x + metrics.groupChipOuterInset
            let chipMaxX = place.x + width
            let end = memberMaxX[group] ?? chipMaxX
            let members = max(0, end - chipMaxX)
            // A band a dragged tab or block stretches follows it exactly; a new band is where it starts.
            let bandMoves = !direct && drag?.targetGroup != group && (band.washLayer.position != .zero || band.washLayer.bounds.width > 0)
            let wash = move.flatMap { _ in bandMoves ? TabStripMove.snapshot(band.washLayer) : nil }
            let line = move.flatMap { _ in bandMoves ? TabStripMove.snapshot(band.lineLayer) : nil }
            band.apply(
                span: CGRect(x: pixel(chipMaxX - offset), y: tabY, width: pixel(members), height: tabHeight),
                lineWidth: members > 0.5 ? pixel(end - pillMinX) : 0,
                lineHeight: metrics.groupUnderlineHeight,
                cornerRadius: metrics.cornerRadius,
                opacity: alpha
            )
            band.lineLayer.frame.origin.x = pixel(pillMinX - offset)
            if let move, let wash, let line {
                move.animate(from: wash)
                move.animate(from: line)
            }
        }
    }

    // MARK: - Hit testing and hover

    func chipGroup(at point: CGPoint) -> TabGroupID? {
        let local = convert(point, to: tabsClip)
        guard local.x >= 0, local.x <= tabsClip.bounds.width, local.y >= 0, local.y <= tabsClip.bounds.height else { return nil }
        guard scrollMapping.showsUnpinned(at: local.x) else { return nil }
        for (group, chip) in groups.chips where !dying.contains(.groupChip(group)) {
            let frame = chip.frame
            if local.x >= frame.minX, local.x < frame.maxX { return group }
        }
        return nil
    }

    func setHoveredChip(_ group: TabGroupID?) {
        guard group != groups.hoveredChip else { return }
        if let old = groups.hoveredChip { groups.chips[old]?.isHovered = false }
        groups.hoveredChip = group
        if let group { groups.chips[group]?.isHovered = true }
    }

    func groupHoverContent(_ group: TabGroupItem) -> TabHoverCardContent {
        let members = displayed.filter { $0.groupID == group.id }.map { $0.title.isEmpty ? Strings.untitled : $0.title }
        return .group(group, memberTitles: members)
    }

    // MARK: - Editor bubble

    /// Opens the Liquid Glass group editor under the chip. The App's
    /// "Edit group" action calls this too.
    public func showGroupEditor(for group: TabGroupID) {
        guard let item = groups.byID[group], let chip = groups.chips[group], let window else { return }
        hoverCards.dismiss(.action)
        let anchor = window.convertToScreen(tabsClip.convert(chip.frame, to: nil))
        groupEditor.show(group: item, anchor: anchor, parent: window, themeAnchor: self)
    }

    /// The group's full menu under its chip (the editor's More row; Option-right-click).
    func showGroupMenu(for group: TabGroupID) {
        guard let menu = contextMenuProvider?(.group(group)), !menu.items.isEmpty, let chip = groups.chips[group] else { return }
        let frame = tabsClip.convert(chip.frame, to: self)
        menuTracking.begin(menu)
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: isFlipped ? frame.maxY + 2 : frame.minY - 2), in: self)
        menuTracking.end()
    }

    /// Click-and-hold on a chip opens the editor.
    func startChipHold(_ group: TabGroupID) {
        groups.holdTask?.cancel()
        let sleep = groups.sleep
        groups.holdTask = Task { [weak self] in
            do { try await sleep(.milliseconds(450)) } catch { return }
            guard let self, !Task.isCancelled, self.groups.press?.groupID == group, self.groups.drag == nil else { return }
            self.groups.press?.openedEditor = true
            self.groups.chips[group]?.isPressed = false
            self.showGroupEditor(for: group)
        }
    }
}
