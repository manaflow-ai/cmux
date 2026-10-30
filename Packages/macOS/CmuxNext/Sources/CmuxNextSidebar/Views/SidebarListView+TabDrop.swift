import AppKit
import CmuxNextDesign
import QuartzCore
// External tab drags driven by the App TabDragSession.
extension SidebarListViewComponents {
    // MARK: - External tab drag
    final class ExternalDrag {
        var proposal: SidebarTabDrop?
        var windowPoint: NSPoint
        var sourceMachine: MachineID?
        /// A tab drag: a tab row's edge goes before that tab.
        var reordersTabRows = false
        /// `externalDragMoved`'s slot dwell, kept for autoscroll's re-hit.
        var slotDwell: CFTimeInterval = 0
        var springTarget: WorkspaceID?
        var springGroupTarget: GroupID?
        var springTask: Task<Void, Never>?
        /// Collapsed groups the spring-load opened: they close again when the drag leaves or ends, except the one
        /// the drop goes into (a drag never changes a group's fold for good, Leo 2026-10-20).
        var springOpened: [GroupID] = []
        /// The slot between two rows the pointer is in, and since when (its gap opens after the dwell).
        var slot: (drop: SidebarTabDrop, since: CFTimeInterval)?
        /// When the slot under a resting pointer opens its gap; nil when none is pending.
        var slotDeadline: CFTimeInterval?
        init(windowPoint: NSPoint, sourceMachine: MachineID?) {
            self.windowPoint = windowPoint
            self.sourceMachine = sourceMachine
        }
    }
    /// Updates an external tab drag at a window point. Returns the proposal
    /// and its highlight rect in this view's coordinates, or nil when the
    /// point is outside the list or no drop is possible there. `slotDwell`:
    /// the slot between two rows opens its new-workspace gap only after the
    /// pointer has stayed in it this long; before that the row under the
    /// pointer takes the tab, so a hand crossing the slot on its way to the
    /// row does not slide the row away from under it (cx-8g6ez).
    func externalDragMoved(windowPoint: NSPoint, sourceMachine: MachineID?, reordersTabRows: Bool = false,
                           slotDwell: CFTimeInterval = 0) -> (SidebarTabDrop, NSRect)? {
        guard drag == nil, !model.isFiltering else { return nil }
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else {
            externalDragExited()
            return nil
        }
        let external = self.external ?? ExternalDrag(windowPoint: windowPoint, sourceMachine: sourceMachine)
        external.windowPoint = windowPoint
        external.sourceMachine = sourceMachine
        external.reordersTabRows = reordersTabRows
        external.slotDwell = slotDwell
        if self.external == nil {
            self.external = external
            setHovered(nil)
        }
        autoscroll.update(windowPoint: windowPoint)
        if let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) {
            let base = SidebarLayout.make(sections: listSections, metrics: metrics, options: options(includeGap: false))
            var proposal = DropResolver.resolveTabDrop(y: baseY, base: base, sections: model.sections, sourceMachine: sourceMachine,
                                                         reordersTabRows: reordersTabRows)
            external.slotDeadline = nil
            if slotDwell > 0, let slot = proposal, case .newWorkspace = slot {
                let now = CACurrentMediaTime()
                if external.slot?.drop != slot { external.slot = (slot, now) }
                let deadline = (external.slot?.since ?? now) + slotDwell
                // Only on a row: the empty list below the last row opens its gap at once.
                if now < deadline, base.row(at: baseY) != nil, let row = DropResolver.resolveTabDrop(
                    y: baseY, base: base, sections: model.sections, sourceMachine: sourceMachine, wholeRows: true),
                   case .intoWorkspace = row {
                    proposal = row
                    external.slotDeadline = deadline
                }
            } else {
                external.slot = nil
            }
            if proposal != external.proposal {
                external.proposal = proposal
                reload(animated: true)
            }
        }
        updateSpringLoad(external)
        guard let proposal = external.proposal, let rect = highlightRect(for: proposal) else { return nil }
        return (proposal, rect)
    }
    /// Where no drop is possible at a window point: why, and the refused
    /// row's rect in this view (tab-dnd: the sidebar previews a refusal
    /// instead of nothing).
    func externalDragRefusal(windowPoint: NSPoint, sourceMachine: MachineID?, reordersTabRows: Bool = false) -> (SidebarTabDropRefusal, NSRect)? {
        guard drag == nil, !model.isFiltering else { return nil }
        let point = convert(windowPoint, from: nil)
        guard let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) else { return nil }
        let base = SidebarLayout.make(sections: listSections, metrics: metrics, options: options(includeGap: false))
        guard let (key, reason) = DropResolver.tabDropRefusal(y: baseY, base: base, sections: model.sections, sourceMachine: sourceMachine,
                                                                 reordersTabRows: reordersTabRows),
              let row = displayed.row(for: key) else { return nil }
        return (reason, frame(for: row))
    }
    /// When the slot under a resting pointer opens its gap (`externalDragMoved`'s dwell).
    var externalDragSlotDeadline: CFTimeInterval? { external?.slotDeadline }
    func externalDragExited() { endExternalDrag(dropping: nil) }
    /// Ends an external drag and returns what it would do. The App commits
    /// the proposal (one daemon command) and updates the model.
    func externalDragEnded() -> SidebarTabDrop? {
        let proposal = external?.proposal
        endExternalDrag(dropping: proposal)
        return proposal
    }
    /// Ends an external drag: the groups its spring-load opened close again, but for the one `drop` goes into.
    private func endExternalDrag(dropping drop: SidebarTabDrop?) {
        guard let external else { return }
        external.springTask?.cancel()
        self.external = nil
        autoscroll.stop()
        let kept = drop.flatMap { Self.dropGroup(of: $0, in: model.sections) }
        for group in external.springOpened where group != kept && model.group(group)?.isCollapsed == false {
            model.send(.toggleCollapse(.group(group)))
        }
        reload(animated: true)
    }
    /// The group a tab drop lands in, if any.
    static func dropGroup(of drop: SidebarTabDrop, in sections: [SidebarSection]) -> GroupID? {
        switch drop {
        case let .intoGroup(group): group
        case let .newWorkspace(_, group, _): group
        case let .intoWorkspace(id), let .beforeTab(id, _): SidebarEdits.position(of: id, in: sections)?.group
        }
    }
    func highlightRect(for proposal: SidebarTabDrop) -> NSRect? {
        switch proposal {
        case let .intoWorkspace(id):
            return displayed.row(for: .workspace(id)).map(frame(for:))
        case let .intoGroup(id):
            return displayed.row(for: .group(id)).map(frame(for:))
        case .newWorkspace:
            return displayed.gapY.map { NSRect(x: inset, y: $0, width: indentWidth, height: displayed.gapHeight) }
        case let .beforeTab(workspace, tab):
            // An insertion line on the tab row's top edge.
            // Inside a group the line starts right of the group's line, as the row does.
            return displayed.row(for: .tab(workspace, tab)).map { row in
                let rowFrame = frame(for: row)
                return NSRect(x: rowFrame.minX, y: rowFrame.minY - 1, width: rowFrame.width, height: 2)
            }
        }
    }
    /// Spring loading: hovering a row for `springLoadDelay` selects
    /// it so the user can keep dragging into that workspace's panes.
    func updateSpringLoad(_ external: ExternalDrag) {
        let target: WorkspaceID? = if case let .intoWorkspace(id)? = external.proposal { id } else { nil }
        let groupTarget: GroupID? = if case let .intoGroup(id)? = external.proposal { id } else { nil }
        guard target != external.springTarget || groupTarget != external.springGroupTarget else { return }
        external.springTask?.cancel()
        external.springTarget = target
        external.springGroupTarget = groupTarget
        guard target != nil || groupTarget != nil else { return }
        let clock = springLoadClock
        let delay = springLoadDelay
        external.springTask = Task { [weak self] in
            // wakeup-allow: one-shot spring-load delay while a tab hovers a row, cancelled when it leaves
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, self.external === external,
                  external.springTarget == target, external.springGroupTarget == groupTarget else { return }
            if let target, self.model.activeWorkspaceID != target {
                self.model.click(target)
            } else if let groupTarget, self.model.group(groupTarget)?.isCollapsed == true {
                external.springOpened.append(groupTarget)
                self.model.send(.toggleCollapse(.group(groupTarget)))
            }
            self.reload(animated: true)
        }
    }
}
