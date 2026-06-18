import Foundation

/// A typed string key for ``CommandPaletteContextSnapshot`` lookups. Carries a
/// `rawValue` so the snapshot can store/read it, and exposes the well-known
/// keys as named values. Each `rawValue` is byte-identical to the string the
/// snapshot persists.
public struct CommandPaletteContextKeys: Hashable, Sendable {
    /// The underlying snapshot dictionary key.
    public let rawValue: String

    /// Wraps a raw snapshot key string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether a workspace is selected.
    public static let hasWorkspace = CommandPaletteContextKeys(rawValue: "workspace.hasSelection")
    /// Selected workspace display name.
    public static let workspaceName = CommandPaletteContextKeys(rawValue: "workspace.name")
    /// Whether the workspace has a custom name.
    public static let workspaceHasCustomName = CommandPaletteContextKeys(rawValue: "workspace.hasCustomName")
    /// Whether the workspace has a custom description.
    public static let workspaceHasCustomDescription = CommandPaletteContextKeys(rawValue: "workspace.hasCustomDescription")
    /// Whether minimal mode is enabled for the workspace.
    public static let workspaceMinimalModeEnabled = CommandPaletteContextKeys(rawValue: "workspace.minimalModeEnabled")
    /// Whether the workspace should offer pinning.
    public static let workspaceShouldPin = CommandPaletteContextKeys(rawValue: "workspace.shouldPin")
    /// Whether the workspace has pull requests.
    public static let workspaceHasPullRequests = CommandPaletteContextKeys(rawValue: "workspace.hasPullRequests")
    /// Whether the workspace has splits.
    public static let workspaceHasSplits = CommandPaletteContextKeys(rawValue: "workspace.hasSplits")
    /// Whether the workspace uses the canvas layout mode.
    public static let workspaceCanvasLayout = CommandPaletteContextKeys(rawValue: "workspace.canvasLayout")
    /// Whether the workspace has sibling workspaces.
    public static let workspaceHasPeers = CommandPaletteContextKeys(rawValue: "workspace.hasPeers")
    /// Whether a workspace exists above the selection.
    public static let workspaceHasAbove = CommandPaletteContextKeys(rawValue: "workspace.hasAbove")
    /// Whether a workspace exists below the selection.
    public static let workspaceHasBelow = CommandPaletteContextKeys(rawValue: "workspace.hasBelow")
    /// Whether mark-read is available for the workspace.
    public static let workspaceCanMarkRead = CommandPaletteContextKeys(rawValue: "workspace.canMarkRead")
    /// Whether mark-unread is available for the workspace.
    public static let workspaceCanMarkUnread = CommandPaletteContextKeys(rawValue: "workspace.canMarkUnread")
    /// Whether the sidebar matches the terminal background.
    public static let sidebarMatchTerminalBackground = CommandPaletteContextKeys(rawValue: "sidebar.matchTerminalBackground")
    /// Whether a panel has focus.
    public static let hasFocusedPanel = CommandPaletteContextKeys(rawValue: "panel.hasFocus")
    /// Focused panel display name.
    public static let panelName = CommandPaletteContextKeys(rawValue: "panel.name")
    /// Whether the focused panel is a browser.
    public static let panelIsBrowser = CommandPaletteContextKeys(rawValue: "panel.isBrowser")
    /// Whether browser focus mode is active.
    public static let panelBrowserFocusModeActive = CommandPaletteContextKeys(rawValue: "panel.browserFocusModeActive")
    /// Whether the browser omnibar is visible.
    public static let panelBrowserOmnibarVisible = CommandPaletteContextKeys(rawValue: "panel.browser.omnibarVisible")
    /// Whether the focused panel is markdown.
    public static let panelIsMarkdown = CommandPaletteContextKeys(rawValue: "panel.isMarkdown")
    /// Whether the focused panel is a terminal.
    public static let panelIsTerminal = CommandPaletteContextKeys(rawValue: "panel.isTerminal")
    /// Whether the focused panel sits in a pane.
    public static let panelHasPane = CommandPaletteContextKeys(rawValue: "panel.hasPane")
    /// Whether the focused panel hosts a forkable agent.
    public static let panelHasForkableAgent = CommandPaletteContextKeys(rawValue: "panel.hasForkableAgent")
    /// Whether the focused panel has a custom name.
    public static let panelHasCustomName = CommandPaletteContextKeys(rawValue: "panel.hasCustomName")
    /// Whether the focused panel should offer pinning.
    public static let panelShouldPin = CommandPaletteContextKeys(rawValue: "panel.shouldPin")
    /// Whether the focused panel has unread state.
    public static let panelHasUnread = CommandPaletteContextKeys(rawValue: "panel.hasUnread")
    /// Whether the focused panel can move to a new workspace.
    public static let panelCanMoveToNewWorkspace = CommandPaletteContextKeys(rawValue: "panel.canMoveToNewWorkspace")
    /// Whether an app update is available.
    public static let updateHasAvailable = CommandPaletteContextKeys(rawValue: "update.hasAvailable")
    /// Whether the cmux CLI is installed in PATH.
    public static let cliInstalledInPATH = CommandPaletteContextKeys(rawValue: "cli.installedInPATH")
    /// Whether cmux is the default terminal.
    public static let defaultTerminalIsDefault = CommandPaletteContextKeys(rawValue: "defaultTerminal.isDefault")
    /// Whether the browser surface is disabled.
    public static let browserDisabled = CommandPaletteContextKeys(rawValue: "browser.disabled")
    /// Whether the user is signed in.
    public static let authSignedIn = CommandPaletteContextKeys(rawValue: "auth.signedIn")
    /// Whether an auth operation is in flight.
    public static let authWorking = CommandPaletteContextKeys(rawValue: "auth.working")

    /// Key for one terminal open-target's availability; `rawValue` is the
    /// target's raw identifier (the app layers a typed overload on top).
    public static func terminalOpenTargetAvailable(rawValue: String) -> CommandPaletteContextKeys {
        CommandPaletteContextKeys(rawValue: "terminal.openTarget.\(rawValue).available")
    }
}
