public import CmuxNextLayout

// Docked workspaces and the window dock (plans/cmux-next/docked-workspace-DESIGN.md, user 2026-11-05): the frame
// operations every entry point (palette, keyboard, CLI, MCP, `action.run`) runs. Each changes `frameDocks` in this
// turn, places the frame in the same turn (`frameDidChange`) and saves the window record on settle; no daemon
// round trip (the frame is window view state). A switch of the stage never touches a docked workspace's view: it
// stays mounted and on screen, so the Chief's draft, scroll position and selection are kept.
public extension WindowDockFrame {
    /// How long a link from the Chief may take to show its workspace and still dock the Chief (``ChiefDockLeave``):
    /// a subagent link may first make its workspace (one daemon round trip).
    static var chiefDockLinkWindow: Duration { .seconds(10) }

    // MARK: Docked workspaces

    /// Docks workspace `id` (one this window lists) at `edge` (W1, W2). A workspace the edge held goes back to the
    /// sidebar; when no workspace is left for the stage, a new one opens there.
    func dockWorkspace(_ id: String, at edge: DockEdge) {
        let keep = frameDocks.dock(at: edge)
        frameDocks.dock(id, at: edge, mode: keep?.mode ?? .docked, extentPermille: keep?.extentPermille ?? WindowDocks.defaultExtentPermille)
        frameDidChange()
        if !frameMembers.contains(where: { !frameDocks.isDocked($0) }) {
            // task-owner: one workspace for the empty stage, bounded by the daemon's reply.
            Task { _ = await frameCreateWorkspace(cwd: nil) }
        }
    }

    /// Workspace `id` leaves its dock and shows on the stage; false when it has no dock.
    func undockWorkspace(_ id: String, show: Bool) -> Bool {
        guard frameDocks.undock(id) else { return false }
        if show, frameFocusedWorkspaceID != id {
            frameShow(id, thisWindow: false)
        } else if frameFocusedWorkspaceID == id {
            frameStageWorkspaceID = id
        }
        frameDidChange()
        return true
    }

    /// Shows or hides the dock at `edge`; with none there, a new workspace opens docked there (in the focused
    /// workspace's directory when `cwd` is nil). Hiding the dock that has the focus gives it to the stage.
    func toggleDock(_ edge: DockEdge, cwd: String?) {
        switch frameDocks.toggle(edge) {
        case .empty:
            // task-owner: one workspace for the empty edge, bounded by the daemon's reply.
            Task { [weak self] in
                guard let made = await self?.frameCreateWorkspace(cwd: cwd) else { return }
                self?.frameDockWhenReported(made, at: edge)
            }
            return
        case .hidden:
            if let focused = frameFocusedWorkspaceID, frameDocks.dock(at: edge)?.workspace == focused, let stage = frameStageWorkspaceID {
                frameShow(stage, thisWindow: false)
            }
        case .shown:
            break
        }
        frameDidChange()
    }

    /// Docked <-> Floating for workspace `id`'s dock; nil when it has none.
    func toggleDockFloating(_ id: String) -> DockMode? {
        let mode = frameDocks.toggleFloating(id)
        if mode != nil { frameDidChange() }
        return mode
    }

    /// Column-major <-> row-major corners (W7).
    func toggleDockOrientation() {
        frameDocks.orientation = frameDocks.orientation == .columnMajor ? .rowMajor : .columnMajor
        frameDidChange()
    }

    // MARK: Chief dock

    /// Arms the Chief dock for a link about to open from Home (`home`, the workspace this window shows): the next
    /// workspace shown goes on the stage with Home docked at `edge` (``dockChiefOnLeave(for:now:)``). Nothing while
    /// the window shows something else, Home is docked already, or window docks are off.
    func armChiefDock(home: String, edge: DockEdge, now: ContinuousClock.Instant = ContinuousClock.now) {
        guard LayoutTunables.dockedWorkspaces.value, frameShownWorkspaceID == home, !frameDocks.isDocked(home) else { return }
        chiefDockOnLeave = ChiefDockLeave(home: home, edge: edge, until: now.advanced(by: Self.chiefDockLinkWindow))
    }

    /// A show of `target` is about to replace the shown workspace: when a link from the Chief armed it and Home is
    /// still the shown workspace, Home docks first, so it stays on screen beside `target` with the same view. Any
    /// show of another workspace takes the arm, used or not.
    func dockChiefOnLeave(for target: String, now: ContinuousClock.Instant = ContinuousClock.now) {
        guard let leave = chiefDockOnLeave, target != leave.home else { return }
        chiefDockOnLeave = nil
        guard now < leave.until, LayoutTunables.dockedWorkspaces.value, frameShownWorkspaceID == leave.home,
              !frameDocks.isDocked(leave.home), !frameDocks.isDocked(target) else { return }
        let keep = frameDocks.dock(at: leave.edge)
        frameDocks.dock(leave.home, at: leave.edge, mode: keep?.mode ?? .docked,
                        extentPermille: keep?.extentPermille ?? WindowDocks.defaultExtentPermille)
        frameStageWorkspaceID = target
    }

    /// Open Chief Dock (Cmd-I): Home (`home`, this window's) docks at `edge` unless it is docked already (a hidden
    /// dock shows again, at its own edge), and takes the focus. The stage keeps the workspace it showed (Home
    /// itself, when it filled the window, gives the stage the most recent other workspace, or a new one).
    func openChiefDock(_ home: String, edge: DockEdge) {
        if frameDocks.isDocked(home) {
            _ = frameDocks.reveal(home)
        } else {
            dockWorkspace(home, at: edge)
        }
        frameShow(home, thisWindow: true)
        frameDidChange()
    }

    // MARK: Any dock

    /// The dock the window-dock actions act on: the one with the focus, else the first shown, else the first hidden.
    var targetDock: WindowDocks.Dock? { frameDocks.target(focused: frameFocusedWorkspaceID) }

    /// Moves the target dock to `edge` (Move Dock to Left/Right/Top/Bottom); false with no dock.
    @discardableResult
    func moveTargetDock(to edge: DockEdge) -> Bool {
        guard let dock = targetDock else { return false }
        frameDocks.move(dock.workspace, to: edge)
        frameDidChange()
        return true
    }

    /// Shows or hides the target dock (Show/Hide Dock); whether it shows now, nil with no dock. Hiding the dock
    /// that has the focus gives it to the stage.
    @discardableResult
    func toggleTargetDock() -> Bool? {
        guard let dock = targetDock else { return nil }
        let result = frameDocks.toggle(dock.edge)
        if result == .hidden, frameFocusedWorkspaceID == dock.workspace, let stage = frameStageWorkspaceID {
            frameShow(stage, thisWindow: false)
        }
        frameDidChange()
        return result == .shown
    }

    /// The target dock's no-tab-bar mode on or off (Show/Hide Dock Tab Bar); the new mode, nil with no dock.
    /// Its panes read it in their strip map (``dockHidesTabBar(of:shownTabs:)``), so each shows or hides its bar now.
    @discardableResult
    func toggleTargetDockTabBar() -> Bool? {
        guard let dock = targetDock, let hides = frameDocks.toggleTabBar(dock.workspace) else { return nil }
        frameSaveRecord()
        return hides
    }

    /// Focus Dock: the target dock shows (when hidden) and its workspace takes the focus; false with no dock.
    @discardableResult
    func focusTargetDock() -> Bool {
        guard let dock = targetDock else { return false }
        _ = frameDocks.reveal(dock.workspace)
        frameShow(dock.workspace, thisWindow: true)
        frameDidChange()
        return true
    }

    /// Whether a pane of workspace `id` showing `shownTabs` tabs draws no tab bar: its dock is in the Home Chief
    /// pane's no-tab-bar mode. Read in a pane's strip map, so a toggle reaches every pane of the dock.
    func dockHidesTabBar(of id: String, shownTabs: Int) -> Bool {
        LayoutTunables.dockedWorkspaces.value && frameDocks.hidesTabBar(of: id, shownTabs: shownTabs)
    }
}
