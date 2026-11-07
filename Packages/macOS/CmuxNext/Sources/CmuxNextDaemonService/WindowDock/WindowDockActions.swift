public import CmuxNextActions
import CmuxNextLayout

/// The window frame's dock actions (plans/cmux-next/docked-workspace-DESIGN.md): Dock Workspace
/// Left/Right/Top/Bottom, Undock Workspace, Float Docked Workspace, Toggle Left/Right/Top/Bottom Dock and Toggle
/// Dock Corners, and the window dock's (user 2026-11-05) Open Chief Dock (Cmd-I), Move Pane to Dock, Move Dock to
/// Left/Right/Top/Bottom, Show/Hide Dock, Show/Hide Dock Tab Bar and Focus Dock. Every entry point (palette,
/// keyboard, CLI verb, MCP, `action.run`) ends in one ``WindowDockFrame`` operation, which changes window view
/// state in this turn: no await, no daemon round trip (a dock on an empty edge, Move Pane to Dock with no dock and
/// Open Chief Dock with no Home yet make their workspace in tracked background work). Off (Debug Settings
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

    /// A link clicked in the Chief (a workspace, tab or subagent link, or a subagent pill; user 2026-11-05: "bring
    /// me to workspace, but with the chief still on the left"): with `home.chiefDock.openBeside` on, `frame` (the
    /// window showing Home) arms its Chief dock first (``WindowDockFrame/armChiefDock(home:edge:now:)``), so the
    /// workspace the link shows goes on the stage while Home stays docked, its view and state untouched. A link
    /// that shows nothing else in this window (a tab right of Home, another window) leaves the arm to lapse.
    public func chiefLinkWillOpen(in frame: (any WindowDockFrame)?) {
        guard host.chiefDockOpensBeside, let frame, let shown = frame.frameShownWorkspaceID,
              host.chiefHome(in: frame.frameWindowID) == shown else { return }
        frame.armChiefDock(home: shown, edge: host.chiefDockEdge)
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
                frame.dockWorkspace(id, at: edge)
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

    /// Open Chief Dock in `frame`: its Home docks and its composer takes the keys. With no Home yet, the Home is
    /// made in tracked background work and docks when it exists. Classic Home has no Home workspace to dock: Go to
    /// Home runs instead.
    private static func openChiefDock(in frame: any WindowDockFrame, _ host: any WindowDockHost, _ registry: ActionRegistry) -> ActionEffect {
        guard !host.chiefHomeIsClassic else {
            return host.chiefShowHome() ? .done : .refused(RefusalStrings.chiefDockUnavailable, quiet: true)
        }
        let edge = host.chiefDockEdge
        if let home = host.chiefHome(in: frame.frameWindowID) {
            frame.openChiefDock(home, edge: edge)
            host.chiefFocusComposer()
            return .done
        }
        // task-owner: one Home for this window (one daemon round trip), then the dock; nothing to show before it.
        registry.track(Task { [weak frame] in
            guard let frame, let made = await host.chiefMakeHome(in: frame.frameWindowID) else {
                return ActionWorkFailure(RefusalStrings.chiefDockUnavailable)
            }
            frame.openChiefDock(made, edge: edge)
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
