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
                motion[id]?.width.target = 0
                motion[id]?.alpha.target = 0
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
                chip.update(group: item, memberCount: count)
                groups.bands[group]?.color = item.colorToken
                continue
            }
            let chip = TabGroupChipCell(group: item, memberCount: count)
            chip.metrics = metrics
            chip.font = Typography.caption
            chip.appearance = effectiveAppearance
            chip.scale = window?.backingScaleFactor ?? 2
            chip.accessibility.setAccessibilityParent(self)
            chip.accessibility.onPress = { [weak self] in self?.model.send(.toggleGroupCollapsed(group)) }
            let band = TabGroupBandCell(color: item.colorToken)
            band.appearance = effectiveAppearance
            if let clip = tabsClip.layer {
                band.addTo(clip)
                clip.addSublayer(chip.layer)
            }
            groups.chips[group] = chip
            groups.bands[group] = band
            motion[id] = TabMotion(x: 0, width: 0, alpha: animated ? 0 : 1)
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
        motion[id] = nil
        dying.remove(id)
        if groups.hoveredChip == group { groups.hoveredChip = nil }
    }

    // MARK: - Frames

    /// Positions chips and bands for the current spring values.
    func applyGroupFrames(offset: CGFloat, tabY: CGFloat, tabHeight: CGFloat, pixel: (CGFloat) -> CGFloat) {
        var memberMaxX: [TabGroupID: CGFloat] = [:]
        for item in displayed {
            guard let group = item.groupID, let m = motion[item.id] else { continue }
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, m.x.value + max(0, m.width.value))
        }
        if let drag, let group = drag.targetGroup, let m = motion[drag.id] {
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, m.x.value + max(0, m.width.value))
        }
        if let placeholder = result.slot(Self.placeholderID), let group = placeholder.groupID {
            memberMaxX[group] = max(memberMaxX[group] ?? -.infinity, placeholder.maxX)
        }
        for (group, chip) in groups.chips {
            guard let m = motion[.groupChip(group)] else { continue }
            let width = max(0, m.width.value)
            let minX = pixel(m.x.value - offset)
            chip.frame = CGRect(x: minX, y: tabY, width: pixel(m.x.value - offset + width) - minX, height: tabHeight)
            let alpha = Float(min(max(m.alpha.value, 0), 1))
            chip.layer.opacity = alpha
            chip.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(chip.frame, to: self))
            guard let band = groups.bands[group] else { continue }
            let pillMinX = m.x.value + metrics.groupChipOuterInset
            let chipMaxX = m.x.value + width
            let end = memberMaxX[group] ?? chipMaxX
            let members = max(0, end - chipMaxX)
            band.apply(
                span: CGRect(x: pixel(chipMaxX - offset), y: tabY, width: pixel(members), height: tabHeight),
                lineWidth: members > 0.5 ? pixel(end - pillMinX) : 0,
                lineHeight: metrics.groupUnderlineHeight,
                cornerRadius: metrics.cornerRadius,
                opacity: alpha
            )
            band.lineLayer.frame.origin.x = pixel(pillMinX - offset)
        }
    }

    // MARK: - Hit testing and hover

    func chipGroup(at point: CGPoint) -> TabGroupID? {
        let local = convert(point, to: tabsClip)
        guard local.x >= 0, local.x <= tabsClip.bounds.width, local.y >= 0, local.y <= tabsClip.bounds.height else { return nil }
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

    /// Hover card for a chip: the group name and its member titles.
    func hoverChip(_ group: TabGroupID) {
        guard !hoverCardSuppressed, let item = groups.byID[group], let chip = groups.chips[group], let window, NSApp.isActive else { return }
        let anchor = window.convertToScreen(tabsClip.convert(chip.frame, to: nil))
        hoverCard.hover(groupHoverContent(item), anchor: anchor, tabWidth: metrics.minInactiveTabWidth, parent: window)
    }

    // MARK: - Editor bubble

    /// Opens the Liquid Glass group editor under the chip. The App's
    /// "Edit group" action calls this too.
    public func showGroupEditor(for group: TabGroupID) {
        guard let item = groups.byID[group], let chip = groups.chips[group], let window else { return }
        hoverCard.hide(allowsQuickReshow: false)
        let anchor = window.convertToScreen(tabsClip.convert(chip.frame, to: nil))
        groupEditor.show(group: item, anchor: anchor, parent: window)
    }

    /// Click-and-hold on a chip opens the editor (Chrome).
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
