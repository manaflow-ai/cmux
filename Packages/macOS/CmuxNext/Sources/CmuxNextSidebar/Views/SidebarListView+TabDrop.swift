import AppKit
import CmuxNextDesign
import QuartzCore
// External tab drags driven by the App TabDragSession.
extension SidebarListView {
    // MARK: - External tab drag
    final class ExternalDrag {
        var proposal: SidebarTabDrop?
        var windowPoint: NSPoint
        var sourceMachine: MachineID?
        var springTarget: WorkspaceID?
        var springGroupTarget: GroupID?
        var springTask: Task<Void, Never>?
        init(windowPoint: NSPoint, sourceMachine: MachineID?) {
            self.windowPoint = windowPoint
            self.sourceMachine = sourceMachine
        }
    }
    /// Updates an external tab drag at a window point. Returns the proposal
    /// and its highlight rect in this view's coordinates, or nil when the
    /// point is outside the list or no drop is possible there.
    func externalDragMoved(windowPoint: NSPoint, sourceMachine: MachineID?) -> (SidebarTabDrop, NSRect)? {
        guard drag == nil, !model.isFiltering else { return nil }
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else {
            externalDragExited()
            return nil
        }
        let external = self.external ?? ExternalDrag(windowPoint: windowPoint, sourceMachine: sourceMachine)
        external.windowPoint = windowPoint
        external.sourceMachine = sourceMachine
        if self.external == nil {
            self.external = external
            setHovered(nil)
        }
        autoscroll.update(windowPoint: windowPoint)
        if let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) {
            let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
            let proposal = DropResolver.resolveTabDrop(y: baseY, base: base, sections: model.sections, sourceMachine: sourceMachine)
            if proposal != external.proposal {
                external.proposal = proposal
                reload(animated: true)
            }
        }
        updateSpringLoad(external)
        guard let proposal = external.proposal, let rect = highlightRect(for: proposal) else { return nil }
        return (proposal, rect)
    }
    func externalDragExited() {
        guard let external else { return }
        external.springTask?.cancel()
        self.external = nil
        autoscroll.stop()
        reload(animated: true)
    }
    /// Ends an external drag and returns what it would do. The App commits
    /// the proposal (one daemon command) and updates the model.
    func externalDragEnded() -> SidebarTabDrop? {
        let proposal = external?.proposal
        externalDragExited()
        return proposal
    }
    func highlightRect(for proposal: SidebarTabDrop) -> NSRect? {
        switch proposal {
        case let .intoWorkspace(id):
            return displayed.row(for: .workspace(id)).map(frame(for:))
        case let .intoGroup(id):
            return displayed.row(for: .group(id)).map(frame(for:))
        case .newWorkspace:
            return displayed.gapY.map { NSRect(x: inset, y: $0, width: max(0, bounds.width - inset * 2), height: displayed.gapHeight) }
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
                self.model.send(.toggleCollapse(.group(groupTarget)))
            }
            self.reload(animated: true)
        }
    }
}
