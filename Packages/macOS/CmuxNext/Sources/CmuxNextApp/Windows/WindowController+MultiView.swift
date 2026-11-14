import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextLayout
import CmuxNextSidebar

// Debug Settings `sidebar.multiView` (Leo 2026-10-21, item D): the window shows the workspaces of
// `WindowState.viewSet` side by side. The focused one is `content` (`state.workspaceID`), the only one the window's
// focus model, titlebar and actions see; the others are parked contents (no focus topology) whose views stay on
// screen in their slots. A press in one focuses it (`ShellWindow.sendEvent`), as does a click on its sidebar row; a
// click on a row off screen shows that workspace alone. `SidebarModel.onScreen` is the set on screen. With the
// toggle off the set stays nil and onScreen empty, also while window docks arrange the frame (`setOnScreen`).
extension WindowController {
    /// The gap between workspaces shown side by side.
    static var multiViewGap: CGFloat { Metrics.space2 }
    /// The setting or Debug toggle, read where the window's show observer tracks it, so turning it off goes back to one workspace.
    static var multiViewEnabled: Bool { SidebarTunables.multiViewOn }

    /// Puts the window frame on screen: its docked workspaces (`window.dockedWorkspaces`, `state.docks`) at their
    /// edges, and on the stage the workspace the sidebar selected, or `state.viewSet` around it (`sidebar.multiView`).
    /// Tells the sidebar which workspaces are on screen. The set drops workspaces that closed or left the window, and
    /// ends (nil) once the stage's workspace is not in it or one is left; docks of such workspaces go too (W3). Runs in
    /// the turn that shows a workspace or a page, so no frame shows the old arrangement.
    func arrangeOnScreen() {
        let multi = SidebarTunables.multiViewOn, docking = LayoutTunables.dockedWorkspaces.value
        // The Chief panel (`WindowController+ChiefPanel`): floating over the stage or docked beside it, never over Home.
        let panel = syncChiefPanel()
        guard multi || docking || panel != nil else { return leaveMultiView() }
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
        let home = frameHome
        docks.prune { alive($0) && $0 != home } // Home never docks as a workspace (an older build's record may hold it)
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
        guard set != nil || !docks.visible.isEmpty || panel != nil else {
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
        var front = Set(floating.compactMap { views[$0].map(ObjectIdentifier.init) })
        if panel != nil, let panelView = chiefPanelView { front.insert(ObjectIdentifier(panelView)) } // above every workspace
        host.stackFloatingDocks(front: front)
        let frame = docks
        host.arrangeContent = { [weak self] bounds in
            // A docked Chief takes its edge first; a floating one leaves the stage the whole area.
            let area = panel.flatMap { self?.chiefPanelView?.place($0, in: bounds, gap: gap) } ?? CGRect(origin: .zero, size: bounds.size)
            let placement = geometry.place(frame, in: area)
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
        guard SidebarTunables.multiViewOn, group == nil, ids.count == 1, let target = content(atScreen: screenPoint),
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
        guard SidebarTunables.multiViewOn || LayoutTunables.dockedWorkspaces.value, let shown = content?.workspace.id,
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
        let value = Self.multiViewEnabled ? Set(ids.map(SidebarWorkspaceID.init)) : []
        if sidebar.model.onScreen != value { sidebar.model.onScreen = value }
    }
}

// Docked workspaces and the window dock (plans/cmux-next/docked-workspace-DESIGN.md): the frame operations are
// CmuxNextDaemonService's (`WindowDockFrame+Operations`); the window gives them its state with one-line forwards.
extension WindowController: WindowDockFrame {
    var frameWindowID: String { state.id }
    var frameDocks: WindowDocks { get { state.docks } set { state.docks = newValue } }
    var frameFocusedWorkspaceID: String? { state.workspaceID }
    var frameStageWorkspaceID: String? { get { state.stageWorkspaceID } set { state.stageWorkspaceID = newValue } }
    var frameShownWorkspaceID: String? { content?.workspace.id }
    var frameMembers: [String] { services.windows.registry.members(of: state.id) }
    func frameShow(_ id: String, thisWindow: Bool) { services.windows.show(workspaceID: id, in: state, from: thisWindow ? .thisWindow : .anywhere) }
    func frameCreateWorkspace(cwd: String?) async -> String? { await services.windows.createWorkspace(cwd: cwd, into: state.id) }
    func frameDockWhenReported(_ id: String, at edge: DockEdge) {
        pendingDocks[id] = edge
        frameDidChange()
    }
    func frameClaim(_ id: String) { services.windows.claim(workspaceID: id, in: state, select: false) }
    func frameSaveRecord() { services.windows.recordSaver.stateDidChange(state) }
    var frameHome: String? { services.home.dock.isClassic ? nil : services.windowHomes.home(in: state.id)?.id }
    var frameChiefPanel: ChiefPanel { get { state.chiefPanel } set { state.chiefPanel = newValue } }
    var frameChiefPanelArm: ContinuousClock.Instant? { get { chiefPanelArm } set { chiefPanelArm = newValue } }
    var frameChiefPanelShown: Bool { chiefPanelView?.isShown(in: root.contentHost) ?? false }
    var frameChiefPanelHasKeys: Bool { frameChiefPanelShown && chiefPanelView?.hasKeys == true }
    func frameChiefPanelLies(toward direction: LayoutDirection) -> Bool { chiefPanelView?.lies(toward: direction, docked: state.chiefPanel.dockedEdge) ?? false }
    func frameFocusChiefPanel() { chiefPanelView?.focusChief((chiefPanelView?.chief as? InternalPageView)?.focusTarget ?? (chiefPanelView?.chief as? HomeHostView)?.focusTarget) }
    func frameFocusStage(toward direction: LayoutDirection?) { focusStagePane(toward: direction) }
    func frameChiefPanelDidChange() { frameDidChange() }

    /// Places the changed frame now and saves the window record on settle.
    func frameDidChange() {
        arrangeOnScreen()
        frameSaveRecord()
    }
}

// The Chief panel's window side (rules: `WindowDockFrame+ChiefPanel`; view: `ChiefPanelView`); it borrows Home's Chief view.
extension WindowController {
    /// Mounts or takes away the panel for this arrangement; the panel when it draws (open, the stage not Home, a
    /// Chief view to hold).
    func syncChiefPanel() -> ChiefPanel? {
        guard chiefPanelBelongsOnScreen, let chief = chiefPanelSource?() ?? homeChiefView() else { removeChiefPanel(); return nil }
        let view = chiefPanelView ?? makeChiefPanelView()
        if view.floating != (state.chiefPanel.dockedEdge == nil) { view.setFloating(state.chiefPanel.dockedEdge == nil) }
        view.mount(in: root.contentHost)
        view.hold(chief)
        return state.chiefPanel
    }

    /// Takes the panel off screen; Home's pane that shows the Chief tab takes its view back.
    func removeChiefPanel() {
        guard let view = chiefPanelView, view.superview != nil else { return }
        let hadKeys = view.hasKeys
        let homeContent = content?.workspace.id == frameHome ? content : frameHome.flatMap { parked[$0] }
        let panes = homeContent.map { Array($0.panes.values) } ?? []
        if let chief = view.release() { for pane in panes where pane.view.content === chief { _ = pane.view.show(chief) } }
        view.unmount()
        if hadKeys, homeContent !== content { frameFocusStage(toward: nil) }
    }

    /// The stage's pane nearest the panel (`direction` says where from), else its focused pane, takes the keys.
    func focusStagePane(toward direction: LayoutDirection?) {
        guard let content, let window else { return }
        let focused = content.focus.state.pane.flatMap(content.paneController(key:))
        let order = focused.flatMap { content.layoutModel.screen(containing: $0.layoutPaneID)?.layout.visualPanes } ?? []
        let nearest = direction.flatMap { $0 == .right || $0 == .down ? order.first : order.last }.flatMap { content.panes[$0] }
        guard let pane = nearest ?? focused else { return }
        content.layoutModel.focus(pane.layoutPaneID, notify: false, source: .keyMove(byPerson: true))
        content.focus.send(.focusPane(pane.layoutPaneID.rawValue, source: .intent))
        chiefPanelView?.yieldKeys(to: window); if let target = pane.currentContent?.focusTarget, window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    /// The view of Home's Chief tab: the Home page in its pinned chat dock (its live view), else a conversation tab.
    private func homeChiefView() -> NSView? {
        guard let home = frameHome, let (workspace, daemon) = services.machines.workspace(id: home) else { return nil }
        return workspace.chiefPanelTabs.lazy.compactMap { tab -> NSView? in tab.page == nil ? self.services.home.tabView(for: tab)
            : self.services.pages.existingView(tab.id) ?? self.services.pages.view(forStoreTab: tab, in: daemon.store, local: daemon.isLocal, window: self) }.first
    }

    private func makeChiefPanelView() -> ChiefPanelView {
        let settings = services.settings, look = ChiefPanelScreenLook(share: { [weak services] in services?.chiefScreenShare }, settings: { settings })
        let view = ChiefPanelView(title: HomeStrings.chiefName, launcher: ChiefLauncherPanel(frames: FloatingChatFrames(defaults: .standard, storageKey: ChiefLauncherPanel.framesKey)), actions: .init(
            toggleDock: { [weak self] in self.map { $0.toggleChiefPanelDock(edge: $0.services.chiefDockEdge) } }, hide: { [weak self] in self?.hideChiefPanel() },
            moved: { [weak self] in self?.state.chiefPanel.floatingFrame = $0; self?.frameChiefPanelDidChange() }, stop: { [weak self] in _ = self?.services.registry.perform(HomeChiefControl.stopAction, invocation: ActionInvocation(origin: .user)) },
            toggleSeesScreen: look.toggle, opened: { [weak self] in look.panelOpened(window: self?.window?.title) }))
        view.follow({ ChiefPanelStyle(rawValue: settings?.snapshot.chiefPanelStyle ?? "") ?? .default }, seesScreen: { look.seesScreen })
        chiefPanelView = view
        return view
    }
}
