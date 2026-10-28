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
        let input = ModelSnapshot(model)
        if hasSynced, window != nil, let last = lastSyncedInput, isAtRest {
            if input == last { return }
            if input.differsOnlyInSelection(from: last) { return syncSelection(input) }
        }
        sync(fromModel: true)
    }

    /// No gesture, drop, close or override in flight: `displayed` is the model's order.
    private var isAtRest: Bool {
        drag == nil && groups.drag == nil && pendingDrop == nil && dying.isEmpty && orderOverride == nil
            && groups.membershipOverride.isEmpty && detachedID == nil && groups.detachedGroupID == nil
    }

    private func syncSelection(_ input: ModelSnapshot) {
        let selected = input.selectedID
        if let lastSelectedID { cells[lastSelectedID]?.isSelected = false }
        if let selected { cells[selected]?.isSelected = true }
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

        // A new tab grows into its slot while its neighbours slide, on one clock, and a closed one
        // gives its room back, only with `ui.animations.newTab` on (hq-1d, Lawrence 2026-10-14: no big
        // animations by default). Off (the default) or under Reduce Motion the strip takes its new
        // places in one step, with no crossfade standing in for the motion (DESIGN P6). A tab that
        // comes or goes during a person's gesture (a drag, a group drag, a drop settling) appears or
        // leaves at once while the gesture's other springs keep running. Reorders keep their motion.
        let ids = Set(ordered.map(\.id))
        let adding = ordered.contains { cells[$0.id] == nil }
        let removing = cells.keys.contains { !ids.contains($0) && !dying.contains($0) }
        let structureAnimates = !(adding || removing) || Motion.tabs.animates(.newTab)
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
        for (id, cell) in cells where !ids.contains(id) && !dying.contains(id) && !handed.values.contains(id) {
            if cellsAnimate {
                // Chrome: it shrinks to the close width with its left edge pinned to the previous
                // tab's right edge (`relayout` pins x), no fade; it goes when the tween ends.
                dying.insert(id)
                let shown = displayed.filter { !dying.contains($0.id) || $0.id == id }.map(\.id)
                if let i = shown.firstIndex(of: id) { closingAnchors[id] = .some(i > 0 ? shown[i - 1] : nil) }
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
            cell?.style = model.style
        }
        applyMultiSelection()
        if newTabButton.isHidden == model.showsNewTabButton {
            newTabButton.isHidden = !model.showsNewTabButton
            needsLayout = true
        }

        relayout(animated: animated || (styleChanged && !reduceMotion), added: added, growsAdded: cellsAnimate && adding,
                 token: cellsAnimate && removing && !adding ? .tabClose : nil)

        let selected = model.selectedID
        if let selected, selected != lastSelectedID || added.contains(selected) {
            reveal(selected, animated: animated)
        }
        lastSelectedID = selected
        refreshHoverCard()
        hasSynced = true
    }

    /// Creates the layers for a new tab and returns its id.
    func makeCell(_ item: TabItem, animated: Bool) -> TabID {
        let cell = TabCell(item: item)
        cell.style = model.style
        cell.metrics = metrics
        cell.titleFont = Typography.body
        cell.themeScope = themeScope
        cell.scale = window?.backingScaleFactor ?? 2
        cell.isWindowMain = windowMain.isMain
        cell.isWindowVisible = windowVisibility.isVisible
        cell.isStripShown = isShownInWindow
        let id = item.id
        cell.accessibility.setAccessibilityParent(self)
        cell.accessibility.onPress = { [weak self] in self?.model.send(.select(id)) }
        cell.accessibility.onClose = { [weak self] in self?.close(id, source: .accessibility) }
        cell.accessibilityToggleAudio = { [weak self] in self?.model.send(.toggleAudioMute(id)) }
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
        placed[id] = nil
        dying.remove(id)
        goesAt[id] = nil
        occlusionEnds[id] = nil
    }
}
