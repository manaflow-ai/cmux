import Foundation

/// Host-supplied pieces that ``CommandPaletteContributionProvider`` cannot build
/// itself because they depend on live app state or app-domain types the package
/// must not import (cmux.json config issues, custom actions, extension sidebar
/// descriptors, Cloud VM commands, settings toggles, color palette, terminal
/// open-targets, and the auth/view/canvas/right-sidebar palette providers).
///
/// Each member is a pre-resolved contribution slice (or a small runtime
    /// predicate) produced app-side, where `String(localized:)` literals and the
    /// host stores live. The provider interleaves these at the exact ordinal
    /// positions the legacy ``ContentView`` builder used, so the assembled list is
    /// byte-faithful.
public struct CommandPaletteContributionHostBlocks {
    /// Whether the inline VS Code open-target is available right now. Gates the
    /// `palette.openFolderInVSCodeInline` command's visibility.
    public let vscodeInlineAvailable: () -> Bool
    /// "Sidebar: <provider>" switch commands for every available sidebar view.
    public let extensionSidebar: [CommandPaletteCommandContribution]
    /// Right-sidebar mode switch commands.
    public let rightSidebarMode: [CommandPaletteCommandContribution]
    /// Right-sidebar tool-pane open commands.
    public let rightSidebarToolPane: [CommandPaletteCommandContribution]
    /// View-domain palette commands (flash panel, task manager).
    public let view: [CommandPaletteCommandContribution]
    /// Canvas-domain palette commands.
    public let canvas: [CommandPaletteCommandContribution]
    /// Cloud VM palette commands.
    public let cloud: [CommandPaletteCommandContribution]
    /// Search keywords for the `palette.mobileConnect` command.
    public let mobileConnectKeywords: [String]
    /// Search keywords for the `palette.makeDefaultTerminal` command. These are
    /// derived app-side from a localized comma-separated string.
    public let makeDefaultTerminalKeywords: [String]
    /// Auth-domain palette commands (sign in / sign out).
    public let auth: [CommandPaletteCommandContribution]
    /// Settings-toggle palette commands.
    public let settingsToggle: [CommandPaletteCommandContribution]
    /// Workspace color palette commands.
    public let workspaceColor: [CommandPaletteCommandContribution]
    /// Identifier-copy palette commands (workspace/panel id copy).
    public let identifierCopy: [CommandPaletteCommandContribution]
    /// "Move Tab to New Workspace" command (zero or one entry).
    public let moveTabToNewWorkspace: [CommandPaletteCommandContribution]
    /// Terminal directory open-target commands.
    public let terminalDirectoryOpenTargets: [CommandPaletteCommandContribution]
    /// cmux.json configuration-issue palette commands.
    public let cmuxConfigIssues: [CommandPaletteCommandContribution]
    /// cmux.json custom-action palette commands.
    public let cmuxConfigCustomActions: [CommandPaletteCommandContribution]

    /// Creates the host-blocks bundle. Every slice defaults to empty and the
    /// availability predicate defaults to `false` so a caller only supplies what
    /// it has.
    public init(
        vscodeInlineAvailable: @escaping () -> Bool = { false },
        extensionSidebar: [CommandPaletteCommandContribution] = [],
        rightSidebarMode: [CommandPaletteCommandContribution] = [],
        rightSidebarToolPane: [CommandPaletteCommandContribution] = [],
        view: [CommandPaletteCommandContribution] = [],
        canvas: [CommandPaletteCommandContribution] = [],
        cloud: [CommandPaletteCommandContribution] = [],
        mobileConnectKeywords: [String] = [],
        makeDefaultTerminalKeywords: [String] = [],
        auth: [CommandPaletteCommandContribution] = [],
        settingsToggle: [CommandPaletteCommandContribution] = [],
        workspaceColor: [CommandPaletteCommandContribution] = [],
        identifierCopy: [CommandPaletteCommandContribution] = [],
        moveTabToNewWorkspace: [CommandPaletteCommandContribution] = [],
        terminalDirectoryOpenTargets: [CommandPaletteCommandContribution] = [],
        cmuxConfigIssues: [CommandPaletteCommandContribution] = [],
        cmuxConfigCustomActions: [CommandPaletteCommandContribution] = []
    ) {
        self.vscodeInlineAvailable = vscodeInlineAvailable
        self.extensionSidebar = extensionSidebar
        self.rightSidebarMode = rightSidebarMode
        self.rightSidebarToolPane = rightSidebarToolPane
        self.view = view
        self.canvas = canvas
        self.cloud = cloud
        self.mobileConnectKeywords = mobileConnectKeywords
        self.makeDefaultTerminalKeywords = makeDefaultTerminalKeywords
        self.auth = auth
        self.settingsToggle = settingsToggle
        self.workspaceColor = workspaceColor
        self.identifierCopy = identifierCopy
        self.moveTabToNewWorkspace = moveTabToNewWorkspace
        self.terminalDirectoryOpenTargets = terminalDirectoryOpenTargets
        self.cmuxConfigIssues = cmuxConfigIssues
        self.cmuxConfigCustomActions = cmuxConfigCustomActions
    }
}
