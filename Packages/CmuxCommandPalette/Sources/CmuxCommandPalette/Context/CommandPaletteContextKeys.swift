import Foundation

/// String keys for ``CommandPaletteContextSnapshot`` lookups.
public enum CommandPaletteContextKeys {
    /// Whether a workspace is selected.
    public static let hasWorkspace = "workspace.hasSelection"
    /// Selected workspace display name.
    public static let workspaceName = "workspace.name"
    /// Whether the workspace has a custom name.
    public static let workspaceHasCustomName = "workspace.hasCustomName"
    /// Whether the workspace has a custom description.
    public static let workspaceHasCustomDescription = "workspace.hasCustomDescription"
    /// Whether minimal mode is enabled for the workspace.
    public static let workspaceMinimalModeEnabled = "workspace.minimalModeEnabled"
    /// Whether the workspace should offer pinning.
    public static let workspaceShouldPin = "workspace.shouldPin"
    /// Whether the workspace has pull requests.
    public static let workspaceHasPullRequests = "workspace.hasPullRequests"
    /// Whether the workspace has splits.
    public static let workspaceHasSplits = "workspace.hasSplits"
    /// Whether the workspace has sibling workspaces.
    public static let workspaceHasPeers = "workspace.hasPeers"
    /// Whether a workspace exists above the selection.
    public static let workspaceHasAbove = "workspace.hasAbove"
    /// Whether a workspace exists below the selection.
    public static let workspaceHasBelow = "workspace.hasBelow"
    /// Whether mark-read is available for the workspace.
    public static let workspaceCanMarkRead = "workspace.canMarkRead"
    /// Whether mark-unread is available for the workspace.
    public static let workspaceCanMarkUnread = "workspace.canMarkUnread"
    /// Whether the sidebar matches the terminal background.
    public static let sidebarMatchTerminalBackground = "sidebar.matchTerminalBackground"
    /// Whether a panel has focus.
    public static let hasFocusedPanel = "panel.hasFocus"
    /// Focused panel display name.
    public static let panelName = "panel.name"
    /// Whether the focused panel is a browser.
    public static let panelIsBrowser = "panel.isBrowser"
    /// Whether browser focus mode is active.
    public static let panelBrowserFocusModeActive = "panel.browserFocusModeActive"
    /// Whether the browser omnibar is visible.
    public static let panelBrowserOmnibarVisible = "panel.browser.omnibarVisible"
    /// Whether the focused panel is markdown.
    public static let panelIsMarkdown = "panel.isMarkdown"
    /// Whether the focused panel is a terminal.
    public static let panelIsTerminal = "panel.isTerminal"
    /// Whether the focused panel sits in a pane.
    public static let panelHasPane = "panel.hasPane"
    /// Whether the focused panel hosts a forkable agent.
    public static let panelHasForkableAgent = "panel.hasForkableAgent"
    /// Whether the focused panel has a custom name.
    public static let panelHasCustomName = "panel.hasCustomName"
    /// Whether the focused panel should offer pinning.
    public static let panelShouldPin = "panel.shouldPin"
    /// Whether the focused panel has unread state.
    public static let panelHasUnread = "panel.hasUnread"
    /// Whether the focused panel can move to a new workspace.
    public static let panelCanMoveToNewWorkspace = "panel.canMoveToNewWorkspace"
    /// Whether an app update is available.
    public static let updateHasAvailable = "update.hasAvailable"
    /// Whether the cmux CLI is installed in PATH.
    public static let cliInstalledInPATH = "cli.installedInPATH"
    /// Whether cmux is the default terminal.
    public static let defaultTerminalIsDefault = "defaultTerminal.isDefault"
    /// Whether the browser surface is disabled.
    public static let browserDisabled = "browser.disabled"
    /// Whether the user is signed in.
    public static let authSignedIn = "auth.signedIn"
    /// Whether an auth operation is in flight.
    public static let authWorking = "auth.working"
    /// Key for one terminal open-target's availability; `rawValue` is the
    /// target's raw identifier (the app layers a typed overload on top).
    public static func terminalOpenTargetAvailable(rawValue: String) -> String {
        "terminal.openTarget.\(rawValue).available"
    }
}
