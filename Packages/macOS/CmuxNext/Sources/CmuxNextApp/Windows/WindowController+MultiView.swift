import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextLayout
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

    /// Puts the window frame on screen: its docked workspaces (`window.dockedWorkspaces`, `state.docks`) at their
    /// edges, and on the stage the workspace the sidebar selected, or `state.viewSet` around it (`sidebar.multiView`).
    /// Tells the sidebar which workspaces are on screen. The set drops workspaces that closed or left the window, and
    /// ends (nil) once the stage's workspace is not in it or one is left; docks of such workspaces go too (W3). Runs in
    /// the turn that shows a workspace or a page, so no frame shows the old arrangement.
    func arrangeOnScreen() {
        let multi = SidebarTunables.multiView.value, docking = LayoutTunables.dockedWorkspaces.value
        guard multi || docking else { return leaveMultiView() }
        guard let content else {
            // A top page or the connecting view fills the content area: no workspace is on screen.
            clearArrangement()
            return setOnScreen([])
        }
        let shown = content.workspace.id
        let members = services.windows.registry.members(of: state.id)
        let listed = Set(members)
        let alive = { (id: String) in id == shown || (listed.contains(id) && self.services.machines.workspace(id: id) != nil) }
        // The frame (docked-workspace-DESIGN.md W3 to W5): docks of workspaces that left go, selecting a hidden
        // docked workspace shows its dock, and the stage keeps its workspace while a dock has the focus.
        var docks = docking ? state.docks : WindowDocks()
        // A workspace Toggle opened for an empty edge docks once the daemon reports it.
        for (id, edge) in pendingDocks where alive(id) {
            pendingDocks[id] = nil
            if docking { docks.dock(id, at: edge) }
        }
        docks.prune(keeping: alive)
        _ = docks.reveal(shown)
        let stage = docks.isEmpty ? shown : docks.stage(focused: shown, previous: state.stageWorkspaceID,
                                                         recency: state.workspaceRecency, listed: members)
        if docking, state.docks != docks || state.stageWorkspaceID != (docks.isEmpty ? nil : stage) {
            state.docks = docks
            state.stageWorkspaceID = docks.isEmpty ? nil : stage
            services.windows.recordSaver.stateDidChange(state)
        }
        let set = multi ? state.viewSet.flatMap { stage.map($0.contains) == true ? $0 : nil }?
            .pruned { $0 == stage || alive($0) }
            .flatMap { $0.ids.count > 1 ? $0 : nil } : nil
        if state.viewSet != set {
            state.viewSet = set
            services.windows.recordSaver.stateDidChange(state)
        }
        guard set != nil || !docks.visible.isEmpty else {
            clearArrangement()
            return setOnScreen([shown])
        }
        let stageIDs = set?.ids ?? stage.map { [$0] } ?? []
        var views: [String: NSView] = [shown: content.contentView]
        for id in stageIDs + docks.visible.map(\.workspace) where id != shown {
            if let companion = companion(id) { views[id] = companion.contentView }
        }
        let host = root.contentHost
        // Companions that left the frame go off screen; the ones in it come on.
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
        let gap = Self.multiViewGap, geometry = WindowFrameGeometry(gap: Self.multiViewGap)
        let floating = Set(docks.visible.filter { $0.mode == .overlay }.map(\.workspace))
        for (id, view) in views { view.applyDockedWorkspaceChrome(floating: floating.contains(id)) }
        host.stackFloatingDocks(front: Set(floating.compactMap { views[$0].map(ObjectIdentifier.init) }))
        let frame = docks
        host.arrangeContent = { bounds in
            let placement = geometry.place(frame, in: CGRect(origin: .zero, size: bounds.size))
            var frames = placement.docks.map { (id: $0.workspace, frame: $0.frame) }
            if let set {
                frames += set.frames(in: placement.stage, gap: gap)
            } else if let stage {
                frames.append((stage, placement.stage))
            }
            for (id, frame) in frames {
                // The host is not flipped: the frame's y runs down.
                views[id]?.frame = CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height).integral
            }
        }
        setOnScreen(Set(views.keys))
    }

    /// A sidebar workspace dropped on `edge` of a pane of a shown workspace (`WorkspaceDropTarget.beside`), the one
    /// on screen under `screenPoint`: it shows on that side of it, and the focused one keeps the focus; one from
    /// another window moves into this one first.
    func placeBeside(_ id: String, edge: TabDropEdge, at screenPoint: CGPoint) {
        guard let shown = content?.workspace.id, let target = content(atScreen: screenPoint)?.workspace.id,
              let set = (state.viewSet ?? .workspace(shown)).placing(id, beside: target, edge: edge) else { return }
        services.windows.claim(workspaceID: id, in: state, select: false)
        // An incognito and a normal window never share a workspace: the claim refused it.
        guard services.windows.registry.members(of: state.id).contains(id) else { return }
        state.viewSet = set
        arrangeOnScreen()
        services.windows.recordSaver.stateDidChange(state)
    }

    /// The half of the shown workspace under `screenPoint` a workspace dropped on `edge` takes (screen coordinates),
    /// where the drag's ghost lands.
    func besideHighlight(_ edge: TabDropEdge, at screenPoint: CGPoint) -> CGRect? {
        guard let view = content(atScreen: screenPoint)?.contentView, let window = view.window else { return nil }
        return WorkspaceViewSet.half(of: window.convertToScreen(view.convert(view.bounds, to: nil)), at: edge, yDown: false)
    }

    /// The edge of the workspace on screen under `screenPoint` (screen coordinates) that one sidebar workspace dragged
    /// there goes beside: the nearest edge, when the point is within `besideEdgeBand` of the content from it. The drag
    /// takes it where the layout has no split edge (`WorkspaceDragResolver.outcome`): Home's pinned dock takes no drop,
    /// and a screen edge dock band would merge the workspace into a new dock of the shown one.
    func besideEdge(at screenPoint: CGPoint, dragging ids: [String], group: String?) -> TabDropEdge? {
        guard SidebarTunables.multiView.value, group == nil, ids.count == 1, let target = content(atScreen: screenPoint),
              ids.first != target.workspace.id, let window = target.contentView.window else { return nil }
        let view = target.contentView
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
        guard SidebarTunables.multiView.value || LayoutTunables.dockedWorkspaces.value, let shown = content?.workspace.id,
              let hit = window?.contentView?.hitTest(windowPoint) else { return }
        for id in besideIDs where id != shown {
            guard let view = parked[id]?.contentView, !view.isHiddenOrHasHiddenAncestor, hit.isDescendant(of: view) else { continue }
            services.windows.show(workspaceID: id, in: state)
            return
        }
    }

    /// The workspaces on screen: the focused one, then the ones shown beside it.
    var onScreenContents: [WorkspaceContentController] {
        guard let content else { return [] }
        let ids = besideIDs.filter { $0 != content.workspace.id }
        guard !ids.isEmpty else { return [content] }
        return [content] + ids.compactMap { id in
            parked[id].flatMap { $0.contentView.superview === root.contentHost && !$0.contentView.isHidden ? $0 : nil }
        }
    }

    /// The workspaces that may be on screen beside the shown one: Floating docks first (they are on top), then the
    /// `sidebar.multiView` set, the other docks and the stage's workspace while a dock has the focus.
    private var besideIDs: [String] {
        let visible = LayoutTunables.dockedWorkspaces.value ? state.docks.visible : []
        var ids = visible.filter { $0.mode == .overlay }.map(\.workspace) + (state.viewSet?.ids ?? [])
        ids += visible.filter { $0.mode != .overlay }.map(\.workspace)
        if LayoutTunables.dockedWorkspaces.value, let stage = state.stageWorkspaceID { ids.append(stage) }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// The workspace on screen whose layout has screen `screenID` (a drop's column or dock anchor).
    func onScreenContent(holdingScreen screenID: String) -> WorkspaceContentController? {
        onScreenContents.first { $0.layoutModel.screens.contains { $0.id.rawValue == screenID } }
    }

    /// The workspace a drop at `screenPoint` goes to: one shown beside the focused one when the point is in its area,
    /// else the focused one (the drag clamps a point off every workspace into its layout).
    func content(atScreen screenPoint: CGPoint) -> WorkspaceContentController? {
        guard let window else { return content }
        let point = window.convertPoint(fromScreen: screenPoint)
        return onScreenContents.dropFirst().first { $0.contentView.bounds.contains($0.contentView.convert(point, from: nil)) } ?? content
    }

    /// A drop into a workspace shown beside the focused one focuses it first, as a press there does, so the drop lands
    /// in the window's focused content: a strip's workspace for a strip drop, the one under the point for a pane
    /// target. Other outcomes (the sidebar, a new window) leave the focus.
    func focusDropTarget(_ outcome: TabDragOutcome, atScreen screenPoint: CGPoint) {
        let target: WorkspaceContentController?
        switch outcome {
        case let .strip(stripID, _, _): target = onScreenContents.first { $0.panes.values.contains { $0.stripModel.stripID == stripID } }
        case .newSplit, .newColumn, .newDock: target = content(atScreen: screenPoint)
        default: return
        }
        guard let target, target !== content else { return }
        services.windows.show(workspaceID: target.workspace.id, in: state)
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
            view.applyDockedWorkspaceChrome(floating: false)
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

// Docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md): the frame operations every entry point (palette,
// CLI, MCP, `action.run`) runs. Each changes `state.docks` in this turn, places the frame in the same turn
// (`arrangeOnScreen`) and saves the window record on settle; no daemon round trip (the frame is window view state).
extension WindowController {
    /// Docks workspace `id` (one this window lists) at `edge` (W1, W2). A workspace the edge held goes back to the
    /// sidebar; when no workspace is left for the stage, a new one opens there.
    func dockWorkspace(_ id: String, at edge: DockEdge) {
        let keep = state.docks.dock(at: edge)
        state.docks.dock(id, at: edge, mode: keep?.mode ?? .docked, extentPermille: keep?.extentPermille ?? WindowDocks.defaultExtentPermille)
        frameDidChange()
        let members = services.windows.registry.members(of: state.id)
        if !members.contains(where: { !state.docks.isDocked($0) }) {
            Task { [services, id = state.id] in _ = await services.windows.createWorkspace(into: id) }
        }
    }

    /// Workspace `id` leaves its dock and shows on the stage; false when it has no dock.
    func undockWorkspace(_ id: String, show: Bool) -> Bool {
        guard state.docks.undock(id) else { return false }
        if show, state.workspaceID != id {
            services.windows.show(workspaceID: id, in: state)
        } else if state.workspaceID == id {
            state.stageWorkspaceID = id
        }
        frameDidChange()
        return true
    }

    /// Shows or hides the dock at `edge`; with none there, a new workspace opens docked there (in the focused
    /// workspace's directory when `cwd` is nil). Hiding the dock that has the focus gives it to the stage.
    func toggleDock(_ edge: DockEdge, cwd: String?) {
        switch state.docks.toggle(edge) {
        case .empty:
            Task { [services, weak self, id = state.id] in
                guard let made = await services.windows.createWorkspace(cwd: cwd, into: id) else { return }
                self?.pendingDocks[made] = edge
                self?.frameDidChange()
            }
            return
        case .hidden:
            if let focused = state.workspaceID, state.docks.dock(at: edge)?.workspace == focused, let stage = state.stageWorkspaceID {
                services.windows.show(workspaceID: stage, in: state)
            }
        case .shown:
            break
        }
        frameDidChange()
    }

    /// Docked <-> Floating for workspace `id`'s dock; nil when it has none.
    func toggleDockFloating(_ id: String) -> DockMode? {
        let mode = state.docks.toggleFloating(id)
        if mode != nil { frameDidChange() }
        return mode
    }

    /// Column-major <-> row-major corners (W7).
    func toggleDockOrientation() {
        state.docks.orientation = state.docks.orientation == .columnMajor ? .rowMajor : .columnMajor
        frameDidChange()
    }

    /// Places the changed frame now and saves the window record on settle.
    func frameDidChange() {
        arrangeOnScreen()
        services.windows.recordSaver.stateDidChange(state)
    }
}
