import AppKit
import CmuxNextDesign
import QuartzCore
// Mouse selection, click-to-collapse, and keyboard navigation.
extension SidebarListViewComponents {
    // MARK: - Mouse
    typealias Press = SidebarPress
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // A drag or press whose release never came here (the app or window lost focus mid-drag, a menu took the
        // mouse-up) ends now: its rows come back where they were, and this press starts clean.
        endPointerGesture()
        hoverCards.dismiss(.click)
        if inlineRename.isActive { inlineRename.end(commit: true) }
        // A click in the list closes the group editor, like a click outside it.
        if groupEditor.isVisible { groupEditor.hide() }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let hit = clickHit(at: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A double-click on a group's name renames it in place; its first click's fold never ran, so no row moves.
        if case let .group(group)? = hit?.key, event.clickCount == 2, flags.isEmpty, isOnGroupName(group, at: point),
           groupNameClick.take(group) {
            press = nil
            SidebarGroupKeys(list: self).setFocus(group, ring: false)
            inlineRename.begin(.group(group), inPlace: true)
            return
        }
        groupNameClick.flush()
        guard let row = hit else {
            press = nil
            // Empty space: a double-click makes a workspace there.
            if event.clickCount == 2, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               let target = displayed.emptyAreaTarget(at: point.y, metrics: metrics), case let .machine(machine) = target.section {
                model.send(.newWorkspace(machine: machine, group: target.group))
            }
            return
        }
        var press = Press(key: row.key, point: point)
        // A click anywhere but a group header or a disclosure takes keyboard focus off them (and off its ring),
        // so a later Return, Space or arrow cannot act on the header or disclosure focused before.
        switch row.key {
        case .group, .doneFold, .showMore: break
        default: SidebarGroupKeys(list: self).setFocus(nil)
        }
        switch row.key {
        case let .workspace(id):
            // A control-click is a right-click: its menu (`menu(for:)`) neither selects nor switches.
            guard !model.isPlaceholder(id), !flags.contains(.control) else {
                self.press = nil
                return
            }
            if event.clickCount == 2, flags.isEmpty {
                self.press = nil
                inlineRename.begin(row.key)
                return
            }
            let (oldItem, oldSelection) = (model.selectedItem, model.selection)
            if modifierSelect(id, flags: flags) {
                // Shift: the drawn range, pinned tiles too; Cmd: toggle; Cmd-Shift: add the range.
            } else if model.selection.contains(id), model.selection.count > 1 {
                // Keep the multi-selection so it can be dragged; collapse it
                // on mouse-up if no drag happens.
                press.deferredClick = id
            } else if SidebarTunables.multiView.value {
                // The multi-view prototype (#23437): a press selects nothing; the release on this row navigates.
                press.clickOnRelease = id
            } else {
                // A click switches at once, on the press (Lawrence 2026-10-21: a switch on the release read as lag).
                // Leo 2026-10-21 ("MOUSE DOWN DRAGGING ... SHOULDN'T BE IMMEDIATELY FOCUSING"): if the press becomes
                // a drag, `beginDrag` puts the shown workspace and the selection back.
                press.switchedOnPress = (model.activeWorkspaceID, model.selection)
                model.click(id)
            }
            // The fill moves now, on the two rows (a switch drew it already, `SidebarSameTurn`).
            if !patchSelection(from: oldItem, oldSelection: oldSelection) { reload(animated: true) }
        case let .group(group):
            // Arrow keys continue from this group; the ring is for keyboard focus only (cx-qno.17).
            SidebarGroupKeys(list: self).setFocus(group, ring: false)
            // Every click toggles, also fast ones (cx-q5jw): the bar collapses or expands.
        case let .item(item):
            // An item opens at once, as a workspace row does (`LayoutItemRef.activatesOnPress`); the press can
            // still drag the row. A new-tab launcher runs on mouse-up, so a press meant as a move makes no tab.
            let id = LayoutItemID(item)
            if model.listedItem(id)?.ref.activatesOnPress == true {
                press.activatedOnPress = true
                model.send(.activateItem(id, opensWorkspace: event.modifierFlags.contains(.option)))
            }
        case .doneFold, .showMore:
            // Keyboard focus moves to the clicked disclosure (no ring), so a ring left on another one cannot take
            // the next Space or Return; the release toggles it.
            SidebarGroupKeys(list: self).focusFold(row.key, ring: false)
        case .section, .emptySection, .emptyGroup, .folder, .block, .status:
            break
        }
        self.press = press
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, !press.cancelled else { return }
        if drag == nil {
            let point = convert(event.locationInWindow, from: nil)
            guard SidebarPress.movedPastThreshold(from: press.point, to: point),
                  !model.locksReorder else { return }
            beginDrag(press)
            guard drag != nil else { return }
        }
        updateDrag(windowPoint: event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if drag != nil {
            finishDrag(at: event.locationInWindow)
            return
        }
        guard let press, !press.cancelled else { return syncRowStates() }
        // A press on one row of a multi-selection that did not drag is a click on that row, wherever the pointer
        // came up: a release a few points off, over the next row, left the whole selection filled (and the next
        // drag lifted every selected row out of its group).
        if let id = press.deferredClick {
            let (oldItem, oldSelection) = (model.selectedItem, model.selection)
            model.click(id)
            if !patchSelection(from: oldItem, oldSelection: oldSelection) { reload(animated: true) }
            return syncRowStates()
        }
        let point = convert(event.locationInWindow, from: nil)
        guard clickHit(at: point)?.key == press.key else { return syncRowStates() }
        switch press.key {
        case let .workspace(id) where press.clickOnRelease == id:
            let (oldItem, oldSelection) = (model.selectedItem, model.selection)
            model.click(id)
            if !patchSelection(from: oldItem, oldSelection: oldSelection) { reload(animated: true) }
            return syncRowStates()
        case .workspace:
            // Mouse-down drew the click on the old and new rows (`patchSelection`) and moved no row: no layout here
            // (u2455: every click laid the whole list out and configured every row).
            return syncRowStates()
        case let .group(group):
            // An empty saved group reopens; any other group toggles.
            if let g = model.group(group), g.isPinned, g.workspaces.isEmpty, g.items.isEmpty {
                model.send(.openGroup(group))
            } else {
                // Lawrence 2026-10-20: a plain click anywhere on the header only collapses or
                // expands it; the more button and a right-click open the editor and the menu.
                // The fold draws itself (`foldGroup`, the group's rows only): no list reload after it. It is the
                // user's own change, so it moves on the spring (calm-sidebar-movement).
                let fold: @MainActor () -> Void = { [weak self] in
                    self?.model.noteUserIntent()
                    self?.model.send(.toggleCollapse(.group(group)))
                }
                // On the name, the fold waits for a possible second click (a rename in place, `SidebarGroupNameClick`).
                if event.clickCount == 1, isOnGroupName(group, at: press.point) {
                    groupNameClick.schedule(group, fold: fold)
                } else {
                    fold()
                }
                return
            }
        case let .section(section):
            model.send(.toggleCollapse(.section(section)))
        case let .item(item):
            // A link opens its page, a tab shows, an app opens, as in the band.
            guard !press.activatedOnPress else { break }
            model.send(.activateItem(LayoutItemID(item), opensWorkspace: event.modifierFlags.contains(.option)))
        case let .status(section):
            model.toggleStatusSection(section)
        case .doneFold, .showMore:
            _ = SidebarFoldAction(list: self).toggle(press.key)
            return
        case let .emptyGroup(group):
            // The group's empty row makes a workspace in it, as the header's + does; the new row lays the list out.
            onGroupEditorItem?(group, "workspaceGroup.newWorkspace")
            return syncRowStates()
        case .emptySection, .folder, .block:
            break
        }
        reload(animated: true)
    }
    /// Whether `point` (list coordinates) is on group `group`'s name or icon.
    func isOnGroupName(_ group: GroupID, at point: NSPoint) -> Bool {
        guard let header = rowViews[.group(group)] as? GroupHeaderRowView else { return false }
        return header.convert(header.nameHitFrame, to: self).contains(point)
    }
    // MARK: - Middle click (MIDDLE-CLICK-CLOSES-WORKSPACE; SidebarMiddleClick)
    override func otherMouseDown(with event: NSEvent) { if !middleClick.down(event, in: self) { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !middleClick.up(event, in: self) { super.otherMouseUp(with: event) } }
    // MARK: - Group header hit testing
    // MARK: - Keyboard
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // F2 renames the active workspace inline.
        if event.keyCode == 120, flags.isEmpty, let active = model.activeWorkspaceID { return inlineRename.begin(.workspace(active)) }
        if event.keyCode == 53 { // Escape
            // A held drag or press (a row's or a block item's) ends as a cancel: its release clicks nothing.
            if escapeSeen() { return }
            if !model.filterText.isEmpty {
                model.filterText = ""
                reload(animated: true)
                return
            }
        }
        if SidebarGroupKeys(list: self).handle(event, flags: flags) { return }
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            let up = event.specialKey == .upArrow
            if flags == [.command, .option] {
                model.moveSelection(up ? .up : .down)
            } else if flags.isEmpty || flags == .shift {
                let order = selectionOrder
                model.moveActive(by: up ? -1 : 1, extending: flags == .shift, visibleOrder: order)
                if flags.isEmpty { forwardStepAhead(up ? -1 : 1, in: order) }
            } else {
                return super.keyDown(with: event)
            }
            // The reload reveals the new active row (close-focus.md).
            reload(animated: true)
        case .carriageReturn?, .enter?:
            if let active = model.activeWorkspaceID { inlineRename.begin(.workspace(active)) }
        case .delete?, .deleteForward?:
            if flags == .command, !model.selection.isEmpty { model.send(.close(model.orderedSelection)) }
        default:
            super.keyDown(with: event)
        }
    }
}
