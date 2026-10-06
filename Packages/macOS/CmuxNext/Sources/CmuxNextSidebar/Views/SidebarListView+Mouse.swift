import AppKit
import CmuxNextDesign
import QuartzCore
// Mouse selection, click-to-collapse, and keyboard navigation.
extension SidebarListView {
    // MARK: - Mouse
    typealias Press = SidebarPress
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        hoverCards.dismiss(.click)
        if inlineRename.isActive { inlineRename.end(commit: true) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let row = displayed.row(at: point.y) else {
            press = nil
            // Empty space: a double-click makes a workspace there.
            if event.clickCount == 2, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               let target = displayed.emptyAreaTarget(at: point.y, metrics: metrics), case let .machine(machine) = target.section {
                model.send(.newWorkspace(machine: machine, group: target.group))
            }
            return
        }
        var press = Press(key: row.key, point: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch row.key {
        case let .workspace(id):
            guard !model.isPlaceholder(id) else {
                self.press = nil
                return
            }
            if event.clickCount == 2, flags.isEmpty {
                self.press = nil
                inlineRename.begin(row.key)
                return
            }
            if flags.contains(.command) {
                model.toggleSelection(id)
            } else if flags.contains(.shift) {
                model.extendSelection(to: id, visibleOrder: visibleWorkspaceOrder)
            } else if model.selection.contains(id), model.selection.count > 1 {
                // Keep the multi-selection so it can be dragged; collapse it
                // on mouse-up if no drag happens.
                press.deferredClick = id
            } else {
                model.click(id)
            }
            reload(animated: true)
        case let .group(group):
            if event.clickCount == 2 {
                // The first click's toggle is still pending (it waits out the
                // double-click interval): cancel it and rename, so the group
                // never collapses and re-expands under the pointer.
                if pendingGroupToggle?.group == group { cancelPendingGroupToggle() }
                self.press = nil
                inlineRename.begin(row.key)
                return
            }
        case let .tab(workspace, tab):
            self.press = nil
            model.send(.selectTab(workspace: workspace, tab: tab))
            return
        case .section, .emptySection:
            break
        }
        self.press = press
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press, !press.cancelled else { return }
        if drag == nil {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= SidebarStyle.dragThreshold,
                  !model.isFiltering else { return }
            beginDrag(press)
            guard drag != nil else { return }
        }
        updateDrag(windowPoint: event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if drag != nil {
            finishDrag()
            return
        }
        guard let press, !press.cancelled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard displayed.row(at: point.y)?.key == press.key else { return }
        switch press.key {
        case .workspace:
            if let id = press.deferredClick { model.click(id) }
        case .tab:
            break
        case let .group(group):
            // An empty saved group reopens; any other group toggles.
            if let g = model.group(group), g.isPinned, g.workspaces.isEmpty {
                model.send(.openGroup(group))
            } else if isOnDisclosure(point, group: group) {
                // The chevron has no double-click meaning: toggle at once.
                model.send(.toggleCollapse(.group(group)))
            } else {
                scheduleGroupToggle(group)
                return
            }
        case let .section(section):
            model.send(.toggleCollapse(.section(section)))
        case .emptySection:
            break
        }
        reload(animated: true)
    }
    // MARK: - Middle click (MIDDLE-CLICK-CLOSES-WORKSPACE; SidebarMiddleClick)
    override func otherMouseDown(with event: NSEvent) { if !middleClick.down(event, in: self) { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !middleClick.up(event, in: self) { super.otherMouseUp(with: event) } }
    // MARK: - Group header single vs double click
    struct PendingGroupToggle {
        let group: GroupID
        let task: Task<Void, Never>
    }
    /// Whether `point` (list coordinates) is on the group's chevron/folder.
    func isOnDisclosure(_ point: NSPoint, group: GroupID) -> Bool {
        guard let view = rowViews[.group(group)] as? GroupHeaderRowView else { return false }
        return view.disclosureFrame.contains(convert(point, to: view))
    }
    /// A single click on a group header's title toggles after the system
    /// double-click interval, so a double-click can rename instead.
    func scheduleGroupToggle(_ group: GroupID) {
        cancelPendingGroupToggle()
        let clock = clickClock
        let delay = groupToggleDelay
        let task = Task { [weak self] in
            // wakeup-allow: one-shot double-click disambiguation delay, cancelled by the second click
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, self.pendingGroupToggle?.group == group else { return }
            self.pendingGroupToggle = nil
            self.model.send(.toggleCollapse(.group(group)))
            self.reload(animated: true)
        }
        pendingGroupToggle = PendingGroupToggle(group: group, task: task)
    }
    func cancelPendingGroupToggle() {
        pendingGroupToggle?.task.cancel()
        pendingGroupToggle = nil
    }
    // MARK: - Keyboard
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        // F2 renames the active workspace inline.
        if event.keyCode == 120, flags.isEmpty, let active = model.activeWorkspaceID { return inlineRename.begin(.workspace(active)) }
        if event.keyCode == 53 { // Escape
            if drag != nil { return cancelDrag() }
            if !model.filterText.isEmpty {
                model.filterText = ""
                reload(animated: true)
                return
            }
        }
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            let up = event.specialKey == .upArrow
            if flags == [.command, .option] {
                model.moveSelection(up ? .up : .down)
            } else if flags.isEmpty || flags == .shift {
                model.moveActive(by: up ? -1 : 1, extending: flags == .shift, visibleOrder: visibleWorkspaceOrder)
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
