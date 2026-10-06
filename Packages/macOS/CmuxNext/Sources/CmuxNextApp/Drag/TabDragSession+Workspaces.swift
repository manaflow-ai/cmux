import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar

// Sidebar workspace drags across windows. A row drag (one workspace, a
// multi-selection, or a group) that leaves its sidebar sideways is handed
// here and flies as the same glass ghost as a tab (row image plus a live
// thumbnail of the workspace's selected tab). Targets: any window's sidebar
// (slot, group header, or row = append), any window's content (append),
// outside every window (new window under the pointer; with every
// workspace of the source window, that window moves instead).
extension TabDragSession {
    /// Installs the handoff on `controller`'s sidebar.
    func installWorkspaceHandoff(on controller: WindowController) {
        controller.sidebar.container.sidebarView.onDragHandoff = { [weak self, weak controller] handoff in
            guard let self, let controller else { return false }
            return self.beginWorkspaces(handoff, from: controller)
        }
    }

    /// Takes over a sidebar drag. False when another drag is running.
    func beginWorkspaces(_ handoff: SidebarDragHandoff, from window: WindowController) -> Bool {
        guard drag == nil else { return false }
        let ids = handoff.workspaceIDs.map(\.rawValue)
        let group: String? = if case let .group(id) = handoff.payload { id.rawValue } else { nil }
        begin(item: .workspaces(ids, group: group), payload: nil, frame: handoff.rowScreenFrame, grabOffset: handoff.grabOffset,
              point: handoff.screenPoint, image: handoff.image, previewTab: previewTab(of: ids.first, in: window),
              draggedCount: ids.count, pane: nil, window: window)
        return true
    }

    /// The tab the ghost previews: the workspace's selected tab in its
    /// window's first pane.
    private func previewTab(of workspaceID: String?, in window: WindowController) -> String? {
        guard let workspaceID, let pane = services.workspace(id: workspaceID)?.screens.first?.panes.first else { return nil }
        return window.state.selection.selection(in: pane.id) ?? pane.tabs.first?.id
    }

    // MARK: Hit testing

    func updateWorkspaces(_ point: CGPoint, drag: Drag) {
        guard case let .workspaces(ids, group) = drag.source.item else { return }
        let controller = window(at: point)
        var sidebarHit: WorkspaceDropTarget?
        var highlight: CGRect?
        var sidebar: SidebarTabDropTarget?
        if let controller {
            let adapter = adapters(for: controller, drag: drag).sidebar
            adapter.sourceMachine = MachineID(ids.first.flatMap { services.machines.daemon(forWorkspace: $0)?.machineID } ?? MachineRegistry.localID)
            drag.touched[ObjectIdentifier(adapter)] = adapter
            if let hit = adapter.hit(screenPoint: point) {
                sidebar = adapter
                sidebarHit = WorkspaceDragResolver.target(for: hit.drop)
                highlight = hit.highlightFrame
            }
        }
        if let previous = drag.workspaceSidebar, previous !== sidebar { previous.dropExited() }
        drag.workspaceSidebar = sidebar
        let sourceID = drag.source.window?.state.id
        let sourceMembers = sourceID.map(services.windows.registry.members(of:)) ?? []
        drag.workspaceOutcome = WorkspaceDragResolver.outcome(
            windowID: controller?.state.id, sidebarHit: sidebarHit, sourceWindowID: sourceID,
            draggingAllOfSource: !sourceMembers.isEmpty && Set(ids).isSuperset(of: sourceMembers),
            isGroup: group != nil, screenPoint: point
        )
        // Never across incognito and normal windows: no drop target there.
        if case .window(let id, _) = drag.workspaceOutcome, services.windows.registry.value.crossesIncognito(ids, to: id) {
            drag.workspaceOutcome = .cancel
        }
        if case .window(_, .window) = drag.workspaceOutcome, highlight == nil {
            highlight = controller?.window?.frame
        }
        drag.workspaceHighlight = drag.workspaceOutcome == .cancel ? nil : highlight
        present(drag)
        wake(drag)
    }

    // MARK: Commit

    /// Ends a workspace drag: commits `outcome` (window membership, plus
    /// the daemon order commands of a sidebar slot) and lands the ghost.
    func finishWorkspaces(_ drag: Drag, commit: Bool) {
        guard case let .workspaces(ids, _) = drag.source.item else { return }
        for provider in drag.touched.values { provider.dropEnded(committed: nil) }
        let outcome = commit ? drag.workspaceOutcome : .cancel
        drag.lifecycle.cancel()
        let workspaceIDs = ids.map(SidebarWorkspaceID.init)
        switch outcome {
        case .cancel:
            land(drag, at: drag.source.screenFrame, cardness: 0, opacity: 0, scale: 1)
            return
        case let .moveWindow(point):
            if let window = drag.source.window?.window {
                window.setFrame(tearOffFrame(drag, at: point, size: window.frame.size), display: true)
            }
        case let .newWindow(point):
            let size = drag.source.window?.window?.frame.size ?? .zero
            if let controller = services.windows.openWindow(workspaces: ids, frame: tearOffFrame(drag, at: point, size: size)) {
                services.windows.bringToFront(controller)
            }
        case let .window(id, target):
            guard let controller = services.windows.controller(for: id) else { break }
            switch target {
            case let .position(position): controller.sidebar.accept(workspaceIDs, at: position)
            case let .intoGroup(group): controller.sidebar.accept(workspaceIDs, intoGroup: group)
            case .window: controller.sidebar.accept(workspaceIDs, at: nil)
            case .merge: break
            }
            services.windows.bringToFront(controller)
        }
        let target = drag.workspaceHighlight ?? drag.motion.targetRect
        let card = drag.motion.targetRect
        land(drag, at: CGRect(x: target.midX - card.width / 2, y: target.midY - card.height / 2, width: card.width, height: card.height),
             cardness: 1, opacity: 0, scale: 0.7)
    }
}

extension TabDragContext {
    /// Workspace drags never resolve tab outcomes; a neutral context.
    static func workspaces(count: Int) -> TabDragContext {
        TabDragContext(sourcePaneID: "", sourcePaneTabCount: 0, sourceWorkspaceID: "", sourceWorkspaceTabCount: 0, draggedTabCount: count)
    }
}
