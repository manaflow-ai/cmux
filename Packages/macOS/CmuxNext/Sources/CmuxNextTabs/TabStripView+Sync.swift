import AppKit
import CmuxNextDesign
import QuartzCore
// Model sync: diffs `TabStripModel` into tab views and spring targets.
extension TabStripView {
    // MARK: - Model sync

    func sync(fromModel: Bool) {
        let modelOrdered = model.orderedTabs
        if fromModel {
            let order = modelOrdered.map(\.id)
            if order != lastModelOrder {
                // The App applied (or overrode) our reorder, or tabs came and went.
                orderOverride = nil
                if let detachedID, !order.contains(detachedID) { self.detachedID = nil }
                if let pendingDrop, !order.contains(pendingDrop.id) {
                    self.pendingDrop = nil
                    dropPlaceholderIndex = nil
                }
                lastModelOrder = order
            }
        }

        var ordered = modelOrdered.filter { $0.id != detachedID }
        if let override = orderOverride {
            if Set(override) == Set(ordered.map(\.id)) {
                let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
                ordered = override.compactMap { byID[$0] }
            } else {
                orderOverride = nil
            }
        }

        let animated = hasSynced && !reduceMotion
        let ids = Set(ordered.map(\.id))
        for (id, view) in tabViews where !ids.contains(id) && !dying.contains(id) {
            if animated {
                dying.insert(id)
                motion[id]?.width.target = 0
                motion[id]?.alpha.target = 0
                view.showsSeparator = false
                view.isHovered = false
            } else {
                removeTab(id)
            }
        }

        var added: Set<TabID> = []
        for item in ordered {
            if let view = tabViews[item.id] {
                dying.remove(item.id)
                view.update(item: item)
                // A torn-out tab dropped back here takes the drop gap's geometry.
                if pendingDrop?.id == item.id { added.insert(item.id) }
            } else {
                let view = TabView(item: item)
                view.style = model.style
                view.metrics = metrics
                view.titleFont = Typography.body
                let id = item.id
                view.onAccessibilityPress = { [weak self] in self?.model.send(.select(id)) }
                view.onAccessibilityClose = { [weak self] in self?.close(id, source: .accessibility) }
                tabsClip.addSubview(view)
                tabViews[id] = view
                motion[id] = Motion(x: 0, width: 0, alpha: animated ? 0 : 1)
                added.insert(id)
            }
        }
        if hasSynced, !added.isEmpty { closingModeWidth = nil }

        if pendingDrop.map({ ids.contains($0.id) }) == true {
            dropPlaceholderIndex = nil
        }

        displayed = ordered
        let styleChanged = lastStyle != nil && lastStyle != model.style
        lastStyle = model.style
        for item in displayed {
            let view = tabViews[item.id]
            view?.isSelected = item.id == model.selectedID
            view?.style = model.style
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

        if let hoveredID {
            if let item = model.tab(hoveredID) {
                hoverCard.refresh(item)
            } else {
                setHovered(nil)
                hoverCard.hide()
            }
        }
        hasSynced = true
    }

    func removeTab(_ id: TabID) {
        tabViews[id]?.removeFromSuperview()
        tabViews[id] = nil
        motion[id] = nil
        dying.remove(id)
        if hoveredID == id { hoveredID = nil }
        if closeHoveredID == id { closeHoveredID = nil }
    }
}
