public import CmuxNextActions
import CmuxNextLayout

/// The window frame's dock actions (plans/cmux-next/docked-workspace-DESIGN.md): Dock Workspace
/// Left/Right/Top/Bottom, Undock Workspace, Float Docked Workspace, Toggle Left/Right/Top/Bottom Dock and Toggle
/// Dock Corners, and the window dock's (user 2026-11-05) Show/Hide Chief (Cmd-I) and its system-wide key, Move Pane to Dock, Move Dock to
/// Left/Right/Top/Bottom, Show/Hide Dock, Show/Hide Dock Tab Bar and Focus Dock. Home never docks as a workspace
/// (user 2026-11-06): Dock Workspace on Home docks the Chief panel (a Chief-only pane, never over Home), and Undock
/// floats it again. Every entry point (palette,
/// keyboard, CLI verb, MCP, `action.run`) ends in one ``WindowDockFrame`` operation, which changes window view
/// state in this turn: no await, no daemon round trip (a dock on an empty edge, Move Pane to Dock with no dock and
/// Show/Hide Chief with no Home yet make their workspace in tracked background work). Off (Debug Settings
/// `window.dockedWorkspaces`), each refuses with that reason.
@MainActor
public struct WindowDockActions {
    let host: any WindowDockHost

    /// - Parameter host: The app's windows, Home and tab moves (`AppServices`).
    public init(host: any WindowDockHost) { self.host = host }

    /// Binds every dock action into `registry`.
    public func bind(into registry: ActionRegistry) {
        bindDockedWorkspaces(into: registry)
        bindWindowDock(into: registry)
    }

    /// A link clicked in the Chief (the open-workspace indicator: a workspace, tab or subagent link, or a subagent
    /// pill): with `home.chiefDock.openBeside` on, `frame` (the window showing Home) arms its Chief panel, so the
    /// workspace the link shows opens with the Chief floating over it (user 2026-11-06), the workspace's layout
    /// untouched. Only this path opens the panel by itself: a workspace opened any other way shows no Chief. A link
    /// that shows nothing else in this window (a tab right of Home, another window) leaves the arm to lapse.
    public func chiefLinkWillOpen(in frame: (any WindowDockFrame)?) {
        guard host.chiefDockOpensBeside, let frame, let shown = frame.frameShownWorkspaceID, frame.frameHome == shown else { return }
        frame.armChiefPanel()
    }

    private func bindDockedWorkspaces(into registry: ActionRegistry) {
        let host = host
        let edges: [(DockEdge, ActionID, ActionID)] = [
            (.left, "workspace.dockLeft", "window.toggleDockLeft"), (.right, "workspace.dockRight", "window.toggleDockRight"),
            (.top, "workspace.dockTop", "window.toggleDockTop"), (.bottom, "workspace.dockBottom", "window.toggleDockBottom"),
        ]
        for (edge, dock, toggle) in edges {
            registry.bindEffect(dock) { invocation in
                guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
                guard let (id, frame) = Self.owner(invocation, host) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
                // Home is the Chief's own place: its Chief docks as a Chief-only pane instead (never Home's other panes).
                if id == frame.frameHome { frame.dockChiefPanel(at: edge) } else { frame.dockWorkspace(id, at: edge) }
                return .done
            }
            registry.bindEffect(toggle) { invocation in
                guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
                guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
                frame.toggleDock(edge, cwd: invocation["cwd"]?.stringValue)
                return .done
            }
            ActionTargetTitles.setPaletteState(toggle, in: registry) {
                LayoutTunables.dockedWorkspaces.value && host.dockActiveFrame?.frameDocks.dock(at: edge)?.hidden == false
            }
        }
        registry.bindEffect("workspace.undock") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let (id, frame) = Self.owner(invocation, host) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            if id == frame.frameHome { return frame.floatChiefPanel() ? .done : .refused(RefusalStrings.workspaceNotDocked) }
            // A person sees it on the stage; automation never moves the view (socket focus policy).
            guard frame.undockWorkspace(id, show: invocation.origin == .user) else { return .refused(RefusalStrings.workspaceNotDocked) }
            return .done
        }
        registry.bindEffect("workspace.toggleDockFloating") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let (id, frame) = Self.owner(invocation, host) else { return .refused(RefusalStrings.noWorkspaceToActOn) }
            guard frame.toggleDockFloating(id) != nil else { return .refused(RefusalStrings.workspaceNotDocked) }
            return .done
        }
        registry.bindEffect("window.toggleDockOrientation") { invocation in
            Self.withFrame(invocation, host) { $0.toggleDockOrientation() }
        }
    }

    private func bindWindowDock(into registry: ActionRegistry) {
        let host = host
        registry.bindEffect("home.openChiefDock") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
            return Self.openChiefDock(in: frame, host, registry)
        }
        // Undock Chief (cmux#37372): a docked Chief panel floats again over the stage, shown.
        registry.bindEffect("home.undockChief") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
            return frame.undockChiefPanel() ? .done : .refused(RefusalStrings.chiefNotDocked)
        }
        // Show/Hide Chief from Any App (Option-Shift-Space): the floating Chief (its own window over every app) shows
        // or hides where the person is, cmux staying behind. Else cmux comes forward; a Chief already showing there
        // takes the keys, else Show/Hide Chief runs (it hides the panel only when cmux was in front).
        registry.bindEffect("home.showHideChiefFromAnyApp") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            if !host.chiefHomeIsClassic, let frame = host.dockFrame(invocation), frame.frameChiefPanel.dockedEdge == nil,
               frame.toggleChiefPanel() { return .done }
            let wasBehind = host.chiefBringAppForward()
            guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
            if wasBehind, frame.frameChiefPanelShown { frame.frameFocusChiefPanel(); return .done }
            return Self.openChiefDock(in: frame, host, registry)
        }
        registry.bindEffect("window.movePaneToDock") { invocation in
            guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
            guard let source = host.dockPaneWorkspace(invocation) else { return .refused(RefusalStrings.noPaneForDock) }
            guard let frame = host.dockFrame(owning: source) else { return .refused(RefusalStrings.noWindowOpen) }
            return Self.movePane(invocation, from: source, in: frame, host, registry)
        }
        let edges: [(ActionID, DockEdge)] = [("window.dockEdgeLeft", .left), ("window.dockEdgeRight", .right),
                                             ("window.dockEdgeTop", .top), ("window.dockEdgeBottom", .bottom)]
        for (id, edge) in edges {
            registry.bindEffect(id) { invocation in
                Self.withDock(invocation, host) { $0.moveTargetDock(to: edge) }
            }
        }
        registry.bindEffect("window.toggleDock") { invocation in
            Self.withDock(invocation, host) { $0.toggleTargetDock() != nil }
        }
        ActionTargetTitles.setPaletteState("window.toggleDock", in: registry) {
            LayoutTunables.dockedWorkspaces.value && host.dockActiveFrame?.targetDock?.hidden == false
        }
        registry.bindEffect("window.toggleDockTabBar") { invocation in
            Self.withDock(invocation, host) { $0.toggleTargetDockTabBar() != nil }
        }
        ActionTargetTitles.setPaletteState("window.toggleDockTabBar", in: registry) {
            LayoutTunables.dockedWorkspaces.value && host.dockActiveFrame?.targetDock?.hidesTabBar == false
        }
        registry.bindEffect("window.focusDock") { invocation in
            // A focus command: it moves the focus inside the window, never the app's (socket focus policy).
            Self.withDock(invocation, host) { $0.focusTargetDock() }
        }
    }

    /// Show/Hide Chief (Cmd-I) in `frame`: the Chief panel hides when it shows, else it opens (floating, or docked
    /// when the person docked it) and its message box takes the keys. In Home, where the Chief already is, Home's
    /// message box takes the keys. With no Home yet, Home is made and shown in tracked background work. Classic Home
    /// has no Home workspace: Go to Home runs instead.
    private static func openChiefDock(in frame: any WindowDockFrame, _ host: any WindowDockHost, _ registry: ActionRegistry) -> ActionEffect {
        guard !host.chiefHomeIsClassic else {
            return host.chiefShowHome() ? .done : .refused(RefusalStrings.chiefDockUnavailable, quiet: true)
        }
        if frame.toggleChiefPanel() { return .done }
        if let home = frame.frameHome ?? host.chiefHome(in: frame.frameWindowID) {
            if frame.frameShownWorkspaceID != home { frame.frameShow(home, thisWindow: true) }
            host.chiefFocusComposer()
            return .done
        }
        // task-owner: one Home for this window (one daemon round trip), then it shows; nothing to show before it.
        registry.track(Task { [weak frame] in
            guard let frame, let made = await host.chiefMakeHome(in: frame.frameWindowID) else {
                return ActionWorkFailure(RefusalStrings.chiefDockUnavailable)
            }
            frame.frameShow(made, thisWindow: true)
            host.chiefFocusComposer()
            return nil
        })
        return .done
    }

    /// Move Pane to Dock: the pane's tabs move, in order, into the target dock's workspace (its focused pane, as a
    /// tab dragged onto it lands), and the dock shows; with no dock, they move into a new workspace that docks at
    /// `home.chiefDock.edge`. The tabs drag back out as from any pane. Refused for a pane that is in a dock
    /// already, or when the dock's workspace is gone.
    private static func movePane(_ invocation: ActionInvocation, from source: String, in frame: any WindowDockFrame,
                                 _ host: any WindowDockHost, _ registry: ActionRegistry) -> ActionEffect {
        guard !frame.frameDocks.isDocked(source) else { return .refused(RefusalStrings.paneAlreadyInDock) }
        if let dock = frame.targetDock {
            guard host.dockMovePane(invocation, into: dock.workspace) else { return .refused(RefusalStrings.dockWorkspaceGone) }
            _ = frame.frameDocks.reveal(dock.workspace)
            frame.frameDidChange()
            return .done
        }
        let edge = host.chiefDockEdge
        // task-owner: the pane's moves into a new workspace (bounded by the daemon's replies), then the dock.
        registry.track(Task { [weak frame] in
            guard let made = await host.dockMovePaneToNewWorkspace(invocation) else { return ActionWorkFailure(RefusalStrings.dockWorkspaceGone) }
            frame?.frameClaim(made)
            frame?.frameDockWhenReported(made, at: edge)
            return nil
        })
        return .done
    }

    /// The targeted workspace (default: the focused one) and the open window that lists it.
    private static func owner(_ invocation: ActionInvocation, _ host: any WindowDockHost) -> (String, any WindowDockFrame)? {
        guard let id = host.dockTargetWorkspace(invocation), let frame = host.dockFrame(owning: id) else { return nil }
        return (id, frame)
    }

    /// Runs `body` on the targeted window (default: the active one).
    private static func withFrame(_ invocation: ActionInvocation, _ host: any WindowDockHost,
                                  _ body: (any WindowDockFrame) -> Void) -> ActionEffect {
        guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
        guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
        body(frame)
        return .done
    }

    /// Runs `body` on the targeted window; refused when it has no dock (`body` answers false).
    private static func withDock(_ invocation: ActionInvocation, _ host: any WindowDockHost,
                                 _ body: (any WindowDockFrame) -> Bool) -> ActionEffect {
        guard LayoutTunables.dockedWorkspaces.value else { return .refused(RefusalStrings.dockedWorkspacesOff) }
        guard let frame = host.dockFrame(invocation) else { return .refused(RefusalStrings.noWindowOpen) }
        return body(frame) ? .done : .refused(RefusalStrings.windowHasNoDock)
    }
}
