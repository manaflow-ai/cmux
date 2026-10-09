import AppKit
import CmuxNextDesign
import QuartzCore
// Model sync: diffs `TabStripModel` into tab cells and spring targets.
extension TabStripView {
    // MARK: - Model sync (`animating: false`: Cmd-T's tab at full width now, one commit with its page)

    public func sync(fromModel: Bool, animating: Bool = true) {
        let modelOrdered = model.orderedTabs
        groups.byID = Dictionary(model.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if fromModel {
            let order = modelOrdered.map(\.id)
            let membership = modelOrdered.map(\.groupID)
            if order != lastModelOrder || membership != groups.lastMembership {
                // The App applied (or overrode) our change, or tabs came and went.
                orderOverride = nil
                groups.membershipOverride = [:]
                if let detachedID, !order.contains(detachedID) { self.detachedID = nil }
                if let detached = groups.detachedGroupID, !membership.contains(detached) { groups.detachedGroupID = nil }
                if let pendingDrop, !order.contains(pendingDrop.id) {
                    self.pendingDrop = nil
                    dropPlaceholderIndex = nil
                }
                lastModelOrder = order
                groups.lastMembership = membership
            }
        }

        var ordered = modelOrdered.filter { tab in
            tab.id != detachedID && (tab.groupID == nil || tab.groupID != groups.detachedGroupID)
        }
        if !groups.membershipOverride.isEmpty {
            for index in ordered.indices {
                if let group = groups.membershipOverride[ordered[index].id] { ordered[index].groupID = group }
            }
        }
        if let override = orderOverride {
            if Set(override) == Set(ordered.map(\.id)) {
                // Duplicate ids (bad model data) keep the first, not trap.
                let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                ordered = override.compactMap { byID[$0] }
            } else {
                orderOverride = nil
            }
        }

        let animated = hasSynced && !reduceMotion && animating
        let ids = Set(ordered.map(\.id))
        for (id, cell) in cells where !ids.contains(id) && !dying.contains(id) {
            if animated {
                dying.insert(id)
                motion[id]?.width.target = 0
                motion[id]?.alpha.target = 0
                cell.showsSeparator = false
                cell.isHovered = false
            } else {
                removeTab(id)
            }
        }

        var added: Set<TabID> = []
        for item in ordered {
            if let cell = cells[item.id] {
                dying.remove(item.id)
                cell.update(item: item)
                // A torn-out tab dropped back here takes the drop gap's geometry.
                if pendingDrop?.id == item.id { added.insert(item.id) }
            } else {
                added.insert(makeCell(item, animated: animated))
            }
        }
        added.formUnion(syncChips(ordered, animated: animated))
        if hasSynced, !added.isEmpty { closingModeWidth = nil }

        if pendingDrop.map({ ids.contains($0.id) }) == true {
            dropPlaceholderIndex = nil
            dropPlaceholderGroup = nil
        }

        displayed = ordered
        let styleChanged = lastStyle != nil && lastStyle != model.style
        lastStyle = model.style
        for item in displayed {
            let cell = cells[item.id]
            cell?.isSelected = item.id == model.selectedID
            cell?.style = model.style
        }
        if newTabButton.isHidden == model.showsNewTabButton {
            newTabButton.isHidden = !model.showsNewTabButton
            needsLayout = true
        }

        relayout(animated: animated || (styleChanged && !reduceMotion), added: added)

        let selected = model.selectedID
        if let selected, selected != lastSelectedID || added.contains(selected) {
            reveal(selected, animated: animated)
        }
        lastSelectedID = selected
        refreshHoverCard()
        hasSynced = true
    }

    /// The strip's window became or stopped being main.
    func windowMainChanged(isMain: Bool) {}

    /// Creates the layers for a new tab and returns its id.
    func makeCell(_ item: TabItem, animated: Bool) -> TabID {
        let cell = TabCell(item: item)
        cell.style = model.style
        cell.metrics = metrics
        cell.titleFont = Typography.body
        cell.themeScope = themeScope
        cell.scale = window?.backingScaleFactor ?? 2
        let id = item.id
        cell.accessibility.setAccessibilityParent(self)
        cell.accessibility.onPress = { [weak self] in self?.model.send(.select(id)) }
        cell.accessibility.onClose = { [weak self] in self?.close(id, source: .accessibility) }
        let element = ObjectIdentifier(cell.accessibility)
        cell.accessibility.onFocus = { [weak self] focused in self?.noteAccessibilityFocus(element, focused) }
        tabsClip.layer?.addSublayer(cell.layer)
        cells[id] = cell
        motion[id] = TabMotion(x: 0, width: 0, alpha: animated ? 0 : 1)
        return id
    }

    func refreshHoverCard() {
        if let hoveredID {
            if let item = model.tab(hoveredID) {
                hoverCard.refresh(item.id)
            } else {
                hoverCards.targetRemoved(TabHoverCardController.targetID(hoveredID))
                setHovered(nil)
            }
        }
        if let chip = groups.hoveredChip {
            if let group = groups.byID[chip] {
                hoverCard.refresh(.groupChip(group.id))
            } else {
                hoverCards.targetRemoved(TabHoverCardController.targetID(.groupChip(chip)))
                setHoveredChip(nil)
            }
        }
        if let shown = groupEditor.shownGroupID {
            if let group = groups.byID[shown] { groupEditor.update(group: group) } else { groupEditor.hide() }
        }
    }

    func removeTab(_ id: TabID) {
        if let group = id.chipGroupID {
            removeChip(group)
            return
        }
        cells[id]?.layer.removeFromSuperlayer()
        if let cell = cells[id] { noteAccessibilityFocus(ObjectIdentifier(cell.accessibility), false) }
        cells[id] = nil
        motion[id] = nil
        dying.remove(id)
        if hoveredID == id { hoveredID = nil }
        if closeHoveredID == id { closeHoveredID = nil }
    }
}
