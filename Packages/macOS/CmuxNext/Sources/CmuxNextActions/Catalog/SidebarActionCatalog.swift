// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum SidebarActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "toggleSidebar",
                title: String(localized: "action.toggleSidebar", defaultValue: "Toggle Left Sidebar", bundle: .module),
                keywords: ["workspaces", "panel", "hide", "show"],
                defaultShortcut: Shortcut("b", modifiers: [.command]), category: .sidebar, symbol: "sidebar.left",
                surfaces: [.palette, .keyboard, .menu], cliName: "sidebar toggle-left", mainMenu: .view
            ),
            ActionDescriptor(
                id: "toggleRightSidebar",
                title: String(localized: "action.toggleRightSidebar", defaultValue: "Toggle Right Sidebar", bundle: .module),
                keywords: ["files", "explorer", "panel"],
                defaultShortcut: Shortcut("b", modifiers: [.option, .command]), category: .sidebar,
                symbol: "sidebar.right", surfaces: [.keyboard, .menu], cliName: "sidebar toggle-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "focusRightSidebar",
                title: String(localized: "action.focusRightSidebar", defaultValue: "Focus Right Sidebar", bundle: .module),
                keywords: ["files", "explorer", "panel"], defaultShortcut: Shortcut("e", modifiers: [.command, .shift]),
                category: .sidebar, symbol: "sidebar.squares.right", surfaces: [.keyboard, .menu],
                cliName: "sidebar focus-right", mainMenu: .view
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFiles",
                title: String(localized: "action.switchRightSidebarToFiles", defaultValue: "Show Files", bundle: .module),
                keywords: ["right sidebar", "explorer"], defaultShortcut: Shortcut("1", modifiers: [.control]),
                category: .sidebar, symbol: "doc.text", surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused], cliName: "sidebar show-files"
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFind",
                title: String(localized: "action.switchRightSidebarToFind", defaultValue: "Show Find", bundle: .module),
                keywords: ["right sidebar", "search"], defaultShortcut: Shortcut("2", modifiers: [.control]),
                category: .sidebar, symbol: "text.magnifyingglass", surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused], cliName: "sidebar show-find"
            ),
            ActionDescriptor(
                id: "switchRightSidebarToSessions",
                title: String(localized: "action.switchRightSidebarToSessions", defaultValue: "Show Vault", bundle: .module),
                keywords: ["right sidebar", "sessions"], defaultShortcut: Shortcut("3", modifiers: [.control]),
                category: .sidebar, symbol: "archivebox", surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused], cliName: "sidebar show-vault"
            ),
            ActionDescriptor(
                id: "switchRightSidebarToFeed",
                title: String(localized: "action.switchRightSidebarToFeed", defaultValue: "Show Feed", bundle: .module),
                keywords: ["right sidebar", "activity"], defaultShortcut: Shortcut("4", modifiers: [.control]),
                category: .sidebar, symbol: "dot.radiowaves.left.and.right", surfaces: [.palette, .keyboard],
                requires: [.rightSidebarFocused], cliName: "sidebar show-feed"
            ),
            ActionDescriptor(
                id: "switchRightSidebarToDock",
                title: String(localized: "action.switchRightSidebarToDock", defaultValue: "Show Dock", bundle: .module),
                keywords: ["right sidebar"], defaultShortcut: Shortcut("5", modifiers: [.control]), category: .sidebar,
                symbol: "dock.rectangle", surfaces: [.palette, .keyboard], requires: [.rightSidebarFocused],
                cliName: "sidebar show-dock"
            ),
            ActionDescriptor(
                id: "switchRightSidebarToMachines",
                title: String(localized: "action.switchRightSidebarToMachines", defaultValue: "Show Cloud", bundle: .module),
                keywords: ["right sidebar", "machines"], defaultShortcut: Shortcut("6", modifiers: [.control]),
                category: .sidebar, symbol: "cloud", surfaces: [.palette, .keyboard], requires: [.rightSidebarFocused],
                cliName: "sidebar show-cloud"
            ),
            ActionDescriptor(
                id: "fileExplorerOpenSelection",
                title: String(localized: "action.fileExplorerOpenSelection", defaultValue: "Open Selection", bundle: .module),
                keywords: ["file explorer"], defaultShortcut: Shortcut(Shortcut.returnKey, modifiers: []),
                category: .sidebar, symbol: "arrow.turn.down.left", surfaces: [.keyboard],
                requires: [.fileExplorerFocused], cliName: "sidebar open-selection"
            ),
            ActionDescriptor(
                id: "fileExplorerOpenSelectionFinderAlias",
                title: String(localized: "action.fileExplorerOpenSelectionFinderAlias", defaultValue: "Open Selection (Finder Style)", bundle: .module),
                keywords: ["file explorer", "finder"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.command]), category: .sidebar,
                symbol: "arrow.down.doc", surfaces: [.keyboard], requires: [.fileExplorerFocused],
                cliName: "sidebar open-selection-finder-style"
            ),
            ActionDescriptor(
                id: "fileExplorerOpenInCmux",
                title: String(localized: "action.fileExplorerOpenInCmux", defaultValue: "Open in cmux", bundle: .module),
                keywords: ["file explorer"], category: .sidebar, symbol: "square.and.arrow.up.on.square",
                surfaces: [.contextMenu], requires: [.fileExplorerFocused], cliName: "sidebar open-in"
            ),
            ActionDescriptor(
                id: "fileExplorerReveal",
                title: String(localized: "action.fileExplorerReveal", defaultValue: "Reveal in Finder", bundle: .module),
                keywords: ["file explorer", "finder"], category: .sidebar, symbol: "folder", surfaces: [.contextMenu],
                requires: [.fileExplorerFocused], cliName: "sidebar reveal-in-finder"
            ),
            ActionDescriptor(
                id: "fileExplorerCopyPath",
                title: String(localized: "action.fileExplorerCopyPath", defaultValue: "Copy Path", bundle: .module),
                keywords: ["file explorer", "path"], category: .sidebar, symbol: "doc.on.doc", surfaces: [.contextMenu],
                requires: [.fileExplorerFocused], cliName: "sidebar copy-path"
            ),
            ActionDescriptor(
                id: "fileExplorerCopyRelativePath",
                title: String(localized: "action.fileExplorerCopyRelativePath", defaultValue: "Copy Relative Path", bundle: .module),
                keywords: ["file explorer", "path"], category: .sidebar, symbol: "doc.on.clipboard",
                surfaces: [.contextMenu], requires: [.fileExplorerFocused], cliName: "sidebar copy-relative-path"
            ),
            ActionDescriptor(
                id: "fileExplorerOpenWith",
                title: String(localized: "action.fileExplorerOpenWith", defaultValue: "Open With…", bundle: .module),
                keywords: ["file explorer", "open in"], category: .sidebar, symbol: "arrow.up.forward.app",
                surfaces: [.contextMenu], requires: [.fileExplorerFocused], arguments: [CatalogArgument.appString],
                cliName: "sidebar open-with"
            ),
            ActionDescriptor(
                id: "vaultFocusSession",
                title: String(localized: "action.vaultFocusSession", defaultValue: "Focus Session", bundle: .module),
                keywords: ["vault", "session"], category: .sidebar, symbol: "scope", surfaces: [.contextMenu],
                cliName: "sidebar focus-session"
            ),
            ActionDescriptor(
                id: "vaultOpenSession",
                title: String(localized: "action.vaultOpenSession", defaultValue: "Open Session", bundle: .module),
                keywords: ["vault", "session"], category: .sidebar, symbol: "archivebox", surfaces: [.contextMenu],
                cliName: "sidebar open-session"
            ),
            ActionDescriptor(
                id: "vaultResumeInNewWorkspace",
                title: String(localized: "action.vaultResumeInNewWorkspace", defaultValue: "Resume Session in New Workspace", bundle: .module),
                keywords: ["vault", "session", "resume"], category: .sidebar, symbol: "play.rectangle",
                surfaces: [.contextMenu], cliName: "sidebar resume-session-in-new-workspace"
            ),
            ActionDescriptor(
                id: "vaultCopyResumeCommand",
                title: String(localized: "action.vaultCopyResumeCommand", defaultValue: "Copy Resume Command", bundle: .module),
                keywords: ["vault", "session", "resume"], category: .sidebar, symbol: "doc.on.doc",
                surfaces: [.contextMenu], cliName: "sidebar copy-resume-command"
            ),
            ActionDescriptor(
                id: "vaultOpenPullRequest",
                title: String(localized: "action.vaultOpenPullRequest", defaultValue: "Open Session Pull Request", bundle: .module),
                keywords: ["vault", "session", "github"], category: .sidebar, symbol: "arrow.triangle.pull",
                surfaces: [.contextMenu], cliName: "sidebar open-session-pull-request"
            ),
            ActionDescriptor(
                id: "checklistEditItem",
                title: String(localized: "action.checklistEditItem", defaultValue: "Edit Checklist Item…", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "pencil", surfaces: [.contextMenu],
                arguments: [CatalogArgument.textString], cliName: "sidebar edit-checklist-item"
            ),
            ActionDescriptor(
                id: "checklistMarkInProgress",
                title: String(localized: "action.checklistMarkInProgress", defaultValue: "Mark Checklist Item In Progress", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "circle.bottomhalf.filled",
                surfaces: [.contextMenu], cliName: "sidebar mark-checklist-item-in-progress"
            ),
            ActionDescriptor(
                id: "checklistCompleteItem",
                title: String(localized: "action.checklistCompleteItem", defaultValue: "Complete Checklist Item", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "checkmark.circle.fill",
                surfaces: [.contextMenu], cliName: "sidebar complete-checklist-item"
            ),
            ActionDescriptor(
                id: "checklistRemoveItem",
                title: String(localized: "action.checklistRemoveItem", defaultValue: "Remove Checklist Item", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "minus.circle", surfaces: [.contextMenu],
                cliName: "sidebar remove-checklist-item"
            ),
            ActionDescriptor(
                id: "checklistOpenAsPane",
                title: String(localized: "action.checklistOpenAsPane", defaultValue: "Open Checklist as Pane", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "list.bullet.rectangle.portrait",
                surfaces: [.contextMenu], cliName: "sidebar open-checklist-as-pane"
            ),
            ActionDescriptor(
                id: "checklistAttachImages",
                title: String(localized: "action.checklistAttachImages", defaultValue: "Attach Images to Checklist Item…", bundle: .module),
                keywords: ["checklist", "todo"], category: .sidebar, symbol: "photo.badge.plus",
                surfaces: [.contextMenu], cliName: "sidebar attach-images-to-checklist-item"
            ),
            ActionDescriptor(
                id: "palette.toggleMatchTerminalBackground",
                title: String(localized: "action.palette.toggleMatchTerminalBackground", defaultValue: "Toggle Match Terminal Background", bundle: .module),
                keywords: ["sidebar", "theme"], category: .sidebar, symbol: "paintbrush", surfaces: [.palette],
                cliName: "sidebar toggle-match-terminal-background"
            ),
            ActionDescriptor(
                id: "palette.enableMinimalMode",
                title: String(localized: "action.palette.enableMinimalMode", defaultValue: "Enable Minimal Mode", bundle: .module),
                keywords: ["sidebar", "compact"], category: .sidebar, symbol: "rectangle.compress.vertical",
                surfaces: [.palette], cliName: "sidebar enable-minimal-mode"
            ),
            ActionDescriptor(
                id: "palette.disableMinimalMode",
                title: String(localized: "action.palette.disableMinimalMode", defaultValue: "Disable Minimal Mode", bundle: .module),
                keywords: ["sidebar", "compact"], category: .sidebar, symbol: "rectangle.expand.vertical",
                surfaces: [.palette], cliName: "sidebar disable-minimal-mode"
            ),
        ]
    }
}
