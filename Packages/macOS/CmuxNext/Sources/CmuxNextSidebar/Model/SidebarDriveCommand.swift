import Foundation

/// A row of a workspace row's drive indicator menu (``SidebarView/driveMenuItem``). The App makes each
/// row from a registered action, so the menu runs the same path as the palette, the File menu and the CLI.
public nonisolated enum SidebarDriveCommand: Hashable, Sendable {
    /// Go to: show the agent's tab.
    case goTo(tab: TabID)
    /// Stop what the agent in `tab` drives: its Computer Use session (`drive` ``SidebarDriveKind/screen``),
    /// or its chat's turn (``SidebarDriveKind/browser``).
    case stop(tab: TabID, drive: SidebarDriveKind)
}
