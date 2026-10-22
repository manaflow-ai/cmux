import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextSidebar

// Debug Settings `sidebar.multiView` (Leo 2026-10-21, item D): the window shows the workspaces of
// `WindowState.viewSet` side by side. The focused one is `content` (`state.workspaceID`), the only one the window's
// focus model, titlebar and actions see; the others are parked contents (no focus topology) whose views stay on
// screen in their slots. A press in one focuses it (`ShellWindow.sendEvent`), as does a click on its sidebar row; a
// click on a row off screen shows that workspace alone. `SidebarModel.onScreen` is the set on screen. With the
// toggle off none of this runs: the set stays nil and onScreen empty.
extension WindowController {
    /// The gap between workspaces shown side by side.
    static var multiViewGap: CGFloat { Metrics.space2 }
    /// The Debug toggle, read where the window's show observer tracks it, so turning it off goes back to one workspace.
    static var multiViewEnabled: Bool { SidebarTunables.multiView.value }

    /// Puts `state.viewSet` on screen around `content` and tells the sidebar which workspaces are on screen. The set
    /// drops workspaces that closed or left the window, and ends (nil) once `content` is not in it or one is left.
    /// Runs in the turn that shows a workspace or a page, so no frame shows the old arrangement.
    func arrangeOnScreen() {
        guard SidebarTunables.multiView.value else { return leaveMultiView() }
        guard let content else {
            // A top page or the connecting view fills the content area: no workspace is on screen.
            clearArrangement()
            return setOnScreen([])
        }
        let shown = content.workspace.id
        let listed = Set(services.windows.registry.members(of: state.id))
        let set = state.viewSet.flatMap { $0.contains(shown) ? $0 : nil }?
            .pruned { $0 == shown || (listed.contains($0) && services.machines.workspace(id: $0) != nil) }
            .flatMap { $0.ids.count > 1 ? $0 : nil }
        if state.viewSet != set {
            state.viewSet = set
            services.windows.recordSaver.stateDidChange(state)
        }
        guard let set else {
            clearArrangement()
            return setOnScreen([shown])
        }
        var views: [String: NSView] = [shown: content.contentView]
        for id in set.ids where id != shown {
            if let companion = companion(id) { views[id] = companion.contentView }
        }
        let host = root.contentHost
        // Companions that left the set go off screen; the ones in it come on.
        for (id, controller) in parked where views[id] == nil && controller.contentView.superview === host && !controller.contentView.isHidden && id != state.workspaceID {
            controller.contentView.isHidden = true
            controller.park(serial: controller.parkedSerial)
        }
        for (id, view) in views {
            // A companion coming on screen draws its attention rings again (parking stopped following them).
            if view.isHidden || view.superview !== host { parked[id]?.followAttention() }
            if view.superview !== host {
                host.addSubview(view)
                view.reparentRootedThemeScope()
                parked[id]?.layoutView.syncWithModel()
            }
            view.autoresizingMask = []
            view.isHidden = false
        }
        let gap = Self.multiViewGap
        host.arrangeContent = { bounds in
            for (id, frame) in set.frames(in: CGRect(origin: .zero, size: bounds.size), gap: gap) {
                // The host is not flipped: the tree's y runs down.
                views[id]?.frame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height).integral
            }
        }
        setOnScreen(Set(views.keys))
    }

    /// A sidebar workspace dropped on `edge` of a pane of the shown workspace (`WorkspaceDropTarget.beside`): it shows
    /// on that side of the shown one, which keeps the focus; one from another window moves into this one first.
    func placeBeside(_ id: String, edge: TabDropEdge) {
        guard let shown = content?.workspace.id, let set = (state.viewSet ?? .workspace(shown)).placing(id, beside: shown, edge: edge) else { return }
        services.windows.claim(workspaceID: id, in: state, select: false)
        // An incognito and a normal window never share a workspace: the claim refused it.
        guard services.windows.registry.members(of: state.id).contains(id) else { return }
        state.viewSet = set
        arrangeOnScreen()
        services.windows.recordSaver.stateDidChange(state)
    }

    /// The half of the shown workspace a workspace dropped on `edge` takes (screen coordinates), where the drag's
    /// ghost lands.
    func besideHighlight(_ edge: TabDropEdge) -> CGRect? {
        guard let view = content?.contentView, let window = view.window else { return nil }
        return WorkspaceViewSet.half(of: window.convertToScreen(view.convert(view.bounds, to: nil)), at: edge, yDown: false)
    }

    /// The edge of the shown workspace that one sidebar workspace dragged to `screenPoint` (screen coordinates) goes
    /// beside: the nearest edge, when the point is within `besideEdgeBand` of the content from it. The drag takes it
    /// where the layout has no split edge (`WorkspaceDragResolver.outcome`): Home's pinned dock takes no drop, and a
    /// screen edge dock band would merge the workspace into a new dock of the shown one.
    func besideEdge(at screenPoint: CGPoint, dragging ids: [String], group: String?) -> TabDropEdge? {
        guard SidebarTunables.multiView.value, group == nil, ids.count == 1, let content, ids.first != content.workspace.id,
              let window = content.contentView.window else { return nil }
        let view = content.contentView
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        guard rect.width > 0, rect.height > 0, rect.contains(screenPoint) else { return nil }
        // Screen y runs up.
        let x = (screenPoint.x - rect.minX) / rect.width, y = (screenPoint.y - rect.minY) / rect.height
        let distances: [(edge: TabDropEdge, distance: CGFloat)] = [(.left, x), (.right, 1 - x), (.bottom, y), (.top, 1 - y)]
        guard let nearest = distances.min(by: { $0.distance < $1.distance }), nearest.distance <= Self.besideEdgeBand else { return nil }
        return nearest.edge
    }

    /// How far in from an edge of the shown workspace (a fraction of its size) a drop still goes beside it there.
    static var besideEdgeBand: CGFloat { 0.25 }

    /// A press in a workspace shown beside the focused one focuses it first, so the press lands in focused content.
    /// The view the press hits decides, so a sheet, popover or floating pane over it keeps the press.
    func focusOnScreenWorkspace(at windowPoint: CGPoint) {
        guard SidebarTunables.multiView.value, let set = state.viewSet, let shown = content?.workspace.id,
              let hit = window?.contentView?.hitTest(windowPoint) else { return }
        for id in set.ids where id != shown {
            guard let view = parked[id]?.contentView, !view.isHiddenOrHasHiddenAncestor, hit.isDescendant(of: view) else { continue }
            services.windows.show(workspaceID: id, in: state)
            return
        }
    }

    /// The parked content of workspace `id`, mounted now when the window has none (a set restored with the window).
    private func companion(_ id: String) -> WorkspaceContentController? {
        guard let (workspace, daemon) = services.machines.workspace(id: id) else { return nil }
        if let kept = parked[id], kept.workspace === workspace, kept.daemon === daemon { return kept }
        parked[id]?.teardown()
        let controller = WorkspaceContentController(workspace: workspace, daemon: daemon, services: services, state: state, parked: true)
        park(controller)
        return controller
    }

    /// One workspace fills the content area again: the others leave the screen (the one a page covers stays for the
    /// root's own swap).
    private func clearArrangement() {
        let host = root.contentHost
        guard host.arrangeContent != nil else { return }
        host.arrangeContent = nil
        for (id, controller) in parked where controller.contentView.superview === host && id != state.workspaceID {
            controller.contentView.isHidden = true
            controller.park(serial: controller.parkedSerial)
        }
        // The workspace a page covers fills the content area again too, so a page closing shows no half-size frame.
        if let view = (content ?? state.workspaceID.flatMap { parked[$0] })?.contentView {
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
        }
    }

    /// The toggle went off: back to one workspace, and nothing of the set kept.
    private func leaveMultiView() {
        if state.viewSet != nil {
            state.viewSet = nil
            services.windows.recordSaver.stateDidChange(state)
        }
        clearArrangement()
        setOnScreen([])
    }

    private func setOnScreen(_ ids: Set<String>) {
        let value = Set(ids.map(SidebarWorkspaceID.init))
        if sidebar.model.onScreen != value { sidebar.model.onScreen = value }
    }
}
