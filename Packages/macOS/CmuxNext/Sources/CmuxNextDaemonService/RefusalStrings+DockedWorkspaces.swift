// Refusals of the docked workspace actions (plans/cmux-next/docked-workspace-DESIGN.md).
nonisolated extension RefusalStrings {
    /// Debug Settings `window.dockedWorkspaces` is off.
    public static var dockedWorkspacesOff: String {
        text("handlers.refusal.dockedWorkspacesOff", "Docked workspaces are a prototype: turn on Debug Settings > Docked workspaces first.")
    }

    /// Undock or Float on a workspace that has no dock.
    public static var workspaceNotDocked: String {
        text("handlers.refusal.workspaceNotDocked", "This workspace is not docked.")
    }

    /// A window-dock action (Move Dock to Left, Show/Hide Dock, Focus Dock…) in a window with no dock.
    public static var windowHasNoDock: String {
        text("handlers.refusal.windowHasNoDock", "This window has no dock. Press Cmd-I to dock the Chief, or move a pane to the dock.")
    }

    /// Move Pane to Dock with no pane focused or named.
    public static var noPaneForDock: String {
        text("handlers.refusal.noPaneForDock", "No pane is focused.")
    }

    /// Move Pane to Dock on a pane that is in a dock already (or holds no tab).
    public static var paneAlreadyInDock: String {
        text("handlers.refusal.paneAlreadyInDock", "This pane is already in the dock.")
    }

    /// Move Pane to Dock while the dock's workspace closed.
    public static var dockWorkspaceGone: String {
        text("handlers.refusal.dockWorkspaceGone", "The dock's workspace is gone.")
    }

    /// Undock Chief while this window's Chief panel is not docked.
    public static var chiefNotDocked: String {
        text("handlers.refusal.chiefNotDocked", "The Chief is not docked.")
    }

    /// Show/Hide Chief while this window has no Home to show the Chief from (classic Home, or Home not ready).
    public static var chiefDockUnavailable: String {
        text("handlers.refusal.chiefDockUnavailable", "The Chief can't dock yet. Open Home first.")
    }
}
