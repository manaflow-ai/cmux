import AppKit
import CmuxNextDesign
import QuartzCore
// Model sync: diffs `TabStripModel` into tab cells and spring targets.
extension TabStripView {
    // MARK: - Model sync (`animating: false`: every tab at its place now, no springs)

    /// Applies the model when it changed since the strip last synced: the App's
    /// calls (a switch shows strip and content in one transaction, L4) and the
    /// observation's echo of the same change do the work once (I6). A tab switch
    /// updates the two cells whose selection changed; geometry never moves
    /// (`TabLayoutEngine` lays tabs out without reading the selection).
    ///
    /// A strip in a window but out of sight (a parked workspace's, a hidden screen bar) lays
    /// nothing out and animates nothing: a script that reorders, renames or moves tabs in
    /// background workspaces costs it no work until it shows, then one sync to the final state
    /// (``syncShown(_:)``; CLAUDE.md "Go past Chrome where cmux is scripted").
    public func syncFromModel() {
        if window != nil, !isShownInWindow {
            modelChangedWhileHidden = true
            return
        }
        layOutPaneIfOneTabChanged()
        let input = ModelSnapshot(model)
        if hasSynced, window != nil, let last = lastSyncedInput {
            // The echo of a change the strip already shows does nothing, also while a closed tab slides
            // out: its move runs on the render server and its completion removes it.
            if input == last, isAtRest(closing: true) { return }
            if isAtRest(), input.differsOnlyInSelection(from: last) { return syncSelection(input) }
        }
        sync(fromModel: true)
    }

    /// One tab or more: the pane lays out again, since a one-tab pane's row is no band over its chat
    /// (`TabStripModel.holdsOneTab`, the pane's `PaneTabRowSharing.offerTabRow(tabs:)`, #33132). Also on a
    /// strip shown again after its tabs changed out of sight (`syncShown`).
    func layOutPaneIfOneTabChanged() {
        guard model.holdsOneTab != laidOutOneTab else { return }
        laidOutOneTab = model.holdsOneTab
        superview?.needsLayout = true
    }

    /// No gesture, drop, close or override in flight: `displayed` is the model's order. `closing`: a
    /// tab that slides out still counts as at rest.
    private func isAtRest(closing: Bool = false) -> Bool {
        drag == nil && groups.drag == nil && pendingDrop == nil && (closing || dying.isEmpty) && orderOverride == nil
            && groups.membershipOverride.isEmpty && detachedID == nil && groups.detachedGroupID == nil
    }

    private func syncSelection(_ input: ModelSnapshot) {
        let selected = input.selectedID
        // Only a cell that lost the selection drops its zoomed state (VoiceOver).
        if let lastSelectedID, lastSelectedID != selected, let cell = cells[lastSelectedID] {
            cell.isSelected = false
            cell.showsZoom = false
        }
        if let selected, let cell = cells[selected] {
            cell.isSelected = true
            cell.showsZoom = input.zoomsSelected // VoiceOver's zoomed state follows the selection
        }
        // The flush corner (`chrome.cornerFlush`): a selection change runs no frame pass, so it reports here.
        if selected != lastSelectedID, CornerFlush.current.isOn || leadsWithSelection { reportCornerLead() }
        let multiChanged = input.multiSelection != lastSyncedInput?.multiSelection
        if multiChanged { applyMultiSelection() }
        lastSyncedInput = input
        // Same geometry: only what the selected tab draws over or hides changes, so a plain switch
        // touches the two tabs whose selection changed and their neighbors' lines, at any tab count.
        if multiChanged {
            TabSeparatorVisibility.apply(to: self)
        } else {
            TabSeparatorVisibility.apply(to: self, around: [lastSelectedID, selected])
        }
        // At rest no tab overlaps another and no mask is on: only a move in flight needs the pass.
        if !movesInFlight.isEmpty || !occlusionEnds.isEmpty { updateOcclusion() }
        if let selected, selected != lastSelectedID { reveal(selected, animated: !reduceMotion) }
        lastSelectedID = selected
        refreshHoverCard()
    }

    public func sync(fromModel: Bool, animating: Bool = true) {
        // Only a model sync runs the order bookkeeping below: an internal sync leaves the echo to run it.
        if fromModel { lastSyncedInput = ModelSnapshot(model) }
        let modelOrdered = model.orderedTabs
        groups.byID = Dictionary(model.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if fromModel {
            let order = modelOrdered.map(\.id)
            let membership = modelOrdered.map(\.groupID)
            if order != lastModelOrder || membership != groups.lastMembership {
                // The App applied (or overrode) our change, or tabs came and went. A multi-tab drop
                // lands one move at a time: its order stays until the last move shows.
                if multiReorderTarget == nil || multiReorderTarget == order { (orderOverride, multiReorderTarget) = (nil, nil) }
                groups.membershipOverride = [:]
                if let detachedID, !order.contains(detachedID) { self.detachedID = nil }
                if let detached = groups.detachedGroupID, !membership.contains(detached) { groups.detachedGroupID = nil }
                if let pendingDrop, !order.contains(pendingDrop.id) { (self.pendingDrop, dropPlaceholderIndex) = (nil, nil) }
                lastModelOrder = order
                groups.lastMembership = membership
            }
        }

        var ordered = modelOrdered.filter { tab in
            tab.id != detachedID && !dragCompanions.contains(tab.id) && (tab.groupID == nil || tab.groupID != groups.detachedGroupID)
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
                (orderOverride, multiReorderTarget) = (nil, nil)
            }
        }

        // A new tab grows into its slot while its neighbours slide, on one clock, with `ui.animations.newTab`
        // on (on by default, hq-1d). A closed one shrinks out while the tabs right of it slide into its room
        // (close case A, Lawrence cmux-ad m49 2026-11-07: "A: animate the tab strip";
        // plans/cmux-next/close-animation/DESIGN.md) on the `tabs` category alone: the new-tab switch says
        // nothing about a close. Motion off or Reduce Motion: the strip takes its new places in one step,
        // with no crossfade standing in for the motion (DESIGN P6). A tab that comes or goes during a
        // person's gesture (a drag, a group drag, a drop settling) appears or leaves at once while the
        // gesture's other springs keep running. Reorders keep their motion.
        let ids = Set(ordered.map(\.id))
        let adding = ordered.contains { cells[$0.id] == nil }
        let removing = cells.keys.contains { !ids.contains($0) && !dying.contains($0) }
        // A tab that moved to another pane is shown there, and one handed to a drag (`detachedID`, a detached group)
        // is under the pointer: either leaves here with no close (`departures`; review F2 on #37735).
        let departing = model.departures.union(modelOrdered.lazy.filter { $0.id == self.detachedID || ($0.groupID != nil && $0.groupID == self.groups.detachedGroupID) }.map(\.id))
        let closing = cells.keys.contains { !ids.contains($0) && !dying.contains($0) && !departing.contains($0) }
        // A pane's last tab never shrinks out: its pane (or its workspace) closes as one (close cases B, C, D).
        let closesLastTab = removing && ordered.isEmpty
        let structureAnimates = (!adding || Motion.tabs.animates(.newTab, in: window)) && !closesLastTab
        let inGesture = drag != nil || groups.drag != nil || pendingDrop != nil
        let animated = hasSynced && !reduceMotion && animating && (structureAnimates || inGesture)
        // Added/closed cells move only outside a gesture; a sync that adds no tab never re-tokens the strip.
        let cellsAnimate = animated && structureAnimates && !inGesture
        if MotionTrace.isEnabled {
            MotionTrace.note("tabs.sync fromModel=\(fromModel) animating=\(animating) animated=\(animated)"
                + " added=\(ordered.filter { cells[$0.id] == nil }.map(\.id.rawValue)) removed=\(cells.keys.filter { !ids.contains($0) }.map(\.rawValue))")
        }
        // A tab taking another's place (`TabStripModel.successors`) gets its cell's place; that cell goes now.
        let handed = model.takeSuccessions(shown: Set(cells.keys), next: ids)
        // A cell handed to its successor stays on the strip as that successor.
        let successor = Dictionary(handed.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        for (id, cell) in cells where !ids.contains(id) && !dying.contains(id) && !handed.values.contains(id) {
            if cellsAnimate, !departing.contains(id) {
                // Chrome: it shrinks to the close width with its left edge pinned to the previous
                // tab's right edge (`relayout` pins x), no fade; it goes when the tween ends.
                dying.insert(id)
                closingAnchors[id] = closingAnchor(of: id, staying: ids, successor: successor)
                placed[id]?.width = metrics.chrome.closeEndWidth
                cell.beginClosing()
            } else {
                removeTab(id)
            }
        }
        var added: Set<TabID> = []
        for item in ordered {
            if let cell = cells[item.id] {
                dying.remove(item.id)
                goesAt[item.id] = nil
                closingAnchors[item.id] = nil
                cell.update(item: item)
                // A torn-out tab dropped back here takes the drop gap's geometry.
                if pendingDrop?.id == item.id { added.insert(item.id) }
            } else if let from = handed[item.id], let place = placed[from], let shown = cells[from] {
                _ = makeCell(item, animated: false)
                placed[item.id] = place
                // It shows where that cell shows now; `relayout` moves it on from there.
                cells[item.id]?.frame = (shown.layer.presentation() ?? shown.layer).frame
                removeTab(from)
            } else {
                added.insert(makeCell(item, animated: cellsAnimate))
            }
        }
        added.formUnion(syncChips(ordered, animated: animated))
        // A departure ends when its tab left the model (shown or not: a torn-out tab has no cell).
        if !model.departures.isEmpty { model.departures.formIntersection(modelOrdered.map(\.id)) }
        if hasSynced, !added.isEmpty {
            // An insert ends closing mode (Chrome).
            closingModeWidth = nil
            closingWatch.end()
        }

        if pendingDrop.map({ ids.contains($0.id) }) == true { (dropPlaceholderIndex, dropPlaceholderGroup) = (nil, nil) }

        displayed = ordered
        let styleChanged = lastStyle != nil && lastStyle != model.style
        lastStyle = model.style
        for item in displayed {
            let cell = cells[item.id]
            cell?.isSelected = item.id == model.selectedID
            cell?.showsZoom = model.zoomsSelected && item.id == model.selectedID
            cell?.style = model.style
        }
        applyMultiSelection()
        if newTabButton.isHidden == model.showsNewTabButton {
            newTabButton.isHidden = !model.showsNewTabButton
            needsLayout = true
        }
        newTabMenuButton.isHidden = !model.showsNewTabButton || !showsTypeChooser

        relayout(animated: animated || (styleChanged && !reduceMotion), added: added, growsAdded: cellsAnimate && adding,
                 token: cellsAnimate && closing && !adding ? .tabClose : nil)

        let selected = model.selectedID
        if let selected, selected != lastSelectedID || added.contains(selected) {
            reveal(selected, animated: animated)
        }
        lastSelectedID = selected
        refreshHoverCard()
        hasSynced = true
    }

    /// The tab a closing tab's left edge stays on (``pinClosingTabs()``): the nearest one left of it that
    /// stays, so tabs closed in one change ("Close Tabs to the Right") all pin to the tab that stays,
    /// whatever order this sync meets them in. When none left of it stays, the strip's first tab (closing
    /// too, it keeps its x); `.some(nil)` for the first tab itself; nil when it is not shown. A tab handed
    /// to a successor in this sync stays as that successor (`successor`: old to new).
    private func closingAnchor(of id: TabID, staying: Set<TabID>, successor: [TabID: TabID]) -> TabID?? {
        guard let index = displayed.firstIndex(where: { $0.id == id }) else { return nil }
        guard index > 0 else { return .some(nil) }
        let left = displayed[..<index]
        for item in left.reversed() {
            if staying.contains(item.id) { return .some(item.id) }
            if let next = successor[item.id] { return .some(next) }
        }
        return .some(left.first?.id)
    }

    /// Creates the layers for a new tab and returns its id.
    func makeCell(_ item: TabItem, animated: Bool) -> TabID {
        let cell = TabCell(item: item)
        cell.style = model.style
        cell.metrics = metrics
        cell.titleFont = Typography.tabTitle
        cell.themeScope = themeScope
        cell.scale = window?.backingScaleFactor ?? 2
        cell.isWindowMain = windowMain.isMain
        cell.isWindowVisible = windowVisibility.isVisible
        cell.isStripShown = isShownInWindow
        frameFixture.outline(cell)
        let id = item.id
        cell.accessibility.setAccessibilityParent(self)
        cell.accessibility.onPress = { [weak self] in self?.model.send(.select(id)) }
        cell.accessibility.onClose = { [weak self] in self?.close(id, source: .accessibility) }
        cell.accessibilityToggleAudio = { [weak self] in self?.model.send(.toggleAudioMute(id)) }
        cell.accessibilityToggleZoom = { [weak self] in self?.model.send(.toggleZoom(id)) }
        let element = ObjectIdentifier(cell.accessibility)
        cell.accessibility.onFocus = { [weak self] focused in self?.noteAccessibilityFocus(element, focused) }
        tabsLayer(isPinned: item.isPinned)?.addSublayer(cell.layer)
        cells[id] = cell
        // Placed by `relayout` (Chrome: an opening tab never fades).
        placed[id] = TabPlace(x: 0, width: 0)
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
        forgetPlace(id)
        closingAnchors[id] = nil
        if hoveredID == id { hoveredID = nil }
        if closeHoveredID == id { closeHoveredID = nil }
        if audioHoveredID == id { setAudioHovered(nil) }
        if pressedAudioID == id { pressedAudioID = nil }
    }

    /// Drops `id`'s place and the moves that tracked it.
    func forgetPlace(_ id: TabID) {
        // A tab or chip that goes no longer counts in the cells' trailing edge (`followWidth`).
        framedCells = nil
        placed[id] = nil
        dying.remove(id)
        goesAt[id] = nil
        occlusionEnds[id] = nil
    }
}
