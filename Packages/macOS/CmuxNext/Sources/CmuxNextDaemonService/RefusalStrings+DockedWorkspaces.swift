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
}
