// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func tabActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "newSurface",
                title: String(localized: "action.newSurface", defaultValue: "New Terminal Tab", bundle: .module),
                keywords: ["tab", "terminal", "create"], defaultShortcut: Shortcut("t", modifiers: [.command]),
                category: .tab, symbol: "plus.square", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [CatalogArgument.cwdString.optional, CatalogArgument.keepBool.optional], targets: [.tab], cliName: "tab new-terminal", startsTerminal: true
            ),
            ActionDescriptor(
                id: "openBrowser",
                title: String(localized: "action.openBrowser", defaultValue: "New Browser Tab", bundle: .module),
                keywords: ["tab", "web", "create"], defaultShortcut: Shortcut("l", modifiers: [.command, .shift]),
                category: .tab, symbol: "globe.badge.chevron.backward", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [CatalogArgument.urlString, CatalogArgument.engineChoice], targets: [.tab], cliName: "tab new-browser"
            ),
            ActionDescriptor(
                id: "openBrowser.webkit",
                title: String(localized: "action.openBrowser.webkit", defaultValue: "New WebKit Tab", bundle: .module),
                keywords: ["tab", "web", "browser", "safari", "webkit", "create"],
                category: .tab, symbol: "safari", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.urlString], targets: [.tab], cliName: "tab new-webkit"
            ),
            ActionDescriptor(
                id: "openBrowser.chromium",
                title: String(localized: "action.openBrowser.chromium", defaultValue: "New Chromium Tab", bundle: .module),
                keywords: ["tab", "web", "browser", "chrome", "chromium", "cef", "extensions", "create"],
                category: .tab, symbol: "circle.circle", surfaces: [.palette, .contextMenu],
                arguments: [CatalogArgument.urlString], targets: [.tab], cliName: "tab new-chromium"
            ),
            ActionDescriptor(
                id: "closeTab", title: String(localized: "action.closeTab", defaultValue: "Close Tab", bundle: .module),
                keywords: ["tab", "remove"], defaultShortcut: Shortcut("w", modifiers: [.command]), category: .tab,
                symbol: "xmark", surfaces: [.palette, .keyboard, .menu], targets: [.tab], cliName: "tab close",
                mainMenu: .file
            ),
            ActionDescriptor(
                id: "closeOtherTabsInPane",
                title: String(localized: "action.closeOtherTabsInPane", defaultValue: "Close Other Tabs", bundle: .module),
                keywords: ["tab", "remove"], defaultShortcut: Shortcut("t", modifiers: [.option, .command]),
                category: .tab, symbol: "xmark.circle", surfaces: [.keyboard, .menu, .contextMenu], targets: [.tab],
                cliName: "tab close-other", mainMenu: .file
            ),
            ActionDescriptor(
                id: "closeTabsToLeft",
                title: String(localized: "action.closeTabsToLeft", defaultValue: "Close Tabs to the Left", bundle: .module),
                keywords: ["tab", "remove"], category: .tab, symbol: "arrow.left.to.line.compact",
                surfaces: [.contextMenu], targets: [.tab], cliName: "tab close-to-left"
            ),
            ActionDescriptor(
                id: "closeTabsToRight",
                title: String(localized: "action.closeTabsToRight", defaultValue: "Close Tabs to the Right", bundle: .module),
                keywords: ["tab", "remove"], category: .tab, symbol: "arrow.right.to.line.compact",
                surfaces: [.contextMenu], targets: [.tab], cliName: "tab close-to-right"
            ),
            ActionDescriptor(
                id: "renameTab",
                title: String(localized: "action.renameTab", defaultValue: "Rename Tab…", bundle: .module),
                keywords: ["tab", "title"], defaultShortcut: Shortcut("r", modifiers: [.command]), category: .tab,
                symbol: "pencil", surfaces: [.palette, .keyboard, .contextMenu],
                arguments: [CatalogArgument.nameString], targets: [.tab], cliName: "tab rename"
            ),
            ActionDescriptor(
                id: "palette.clearTabName",
                title: String(localized: "action.palette.clearTabName", defaultValue: "Clear Tab Name", bundle: .module),
                keywords: ["tab", "title", "reset"], category: .tab, symbol: "pencil.slash",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab clear-name"
            ),
            ActionDescriptor(
                id: "nextSurface",
                title: String(localized: "action.nextSurface", defaultValue: "Next Tab", bundle: .module),
                keywords: ["tab", "switch"], defaultShortcut: Shortcut("]", modifiers: [.command, .shift]),
                category: .tab, symbol: "chevron.right.square", surfaces: [.palette, .keyboard, .menu], targets: [.tab],
                cliName: "tab next", mainMenu: .file
            ),
            ActionDescriptor(
                id: "prevSurface",
                title: String(localized: "action.prevSurface", defaultValue: "Previous Tab", bundle: .module),
                keywords: ["tab", "switch"], defaultShortcut: Shortcut("[", modifiers: [.command, .shift]),
                category: .tab, symbol: "chevron.left.square", surfaces: [.palette, .keyboard, .menu], targets: [.tab],
                cliName: "tab previous", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceLeft",
                title: String(localized: "action.moveSurfaceLeft", defaultValue: "Move Tab Left", bundle: .module),
                keywords: ["tab", "reorder"], defaultShortcut: Shortcut("[", modifiers: [.shift, .option, .command]),
                category: .tab, symbol: "arrow.left", surfaces: [.keyboard, .menu], targets: [.tab],
                cliName: "tab move-left", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceRight",
                title: String(localized: "action.moveSurfaceRight", defaultValue: "Move Tab Right", bundle: .module),
                keywords: ["tab", "reorder"], defaultShortcut: Shortcut("]", modifiers: [.shift, .option, .command]),
                category: .tab, symbol: "arrow.right", surfaces: [.keyboard, .menu], targets: [.tab],
                cliName: "tab move-right", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToPreviousPane",
                title: String(localized: "action.moveSurfaceToPreviousPane", defaultValue: "Move Tab to Previous Pane", bundle: .module),
                keywords: ["tab", "pane"], defaultShortcut: Shortcut("[", modifiers: [.control, .shift, .command]),
                category: .tab, symbol: "arrow.backward.to.line", surfaces: [.palette, .keyboard, .menu],
                targets: [.tab], cliName: "tab move-to-previous-pane", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToNextPane",
                title: String(localized: "action.moveSurfaceToNextPane", defaultValue: "Move Tab to Next Pane", bundle: .module),
                keywords: ["tab", "pane"], defaultShortcut: Shortcut("]", modifiers: [.control, .shift, .command]),
                category: .tab, symbol: "arrow.forward.to.line", surfaces: [.palette, .keyboard, .menu],
                targets: [.tab], cliName: "tab move-to-next-pane", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneLeft",
                title: String(localized: "action.moveSurfaceToPaneLeft", defaultValue: "Move Tab to Pane Left", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.leftArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab, symbol: "arrow.left.square.fill", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.tab], cliName: "tab move-to-pane-left", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneRight",
                title: String(localized: "action.moveSurfaceToPaneRight", defaultValue: "Move Tab to Pane Right", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.rightArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab, symbol: "arrow.right.square.fill", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.tab], cliName: "tab move-to-pane-right", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneUp",
                title: String(localized: "action.moveSurfaceToPaneUp", defaultValue: "Move Tab to Pane Above", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.shift, .option, .command]), category: .tab,
                symbol: "arrow.up.square.fill", surfaces: [.palette, .keyboard, .menu, .contextMenu], targets: [.tab],
                cliName: "tab move-to-pane-above", mainMenu: .file
            ),
            ActionDescriptor(
                id: "moveSurfaceToPaneDown",
                title: String(localized: "action.moveSurfaceToPaneDown", defaultValue: "Move Tab to Pane Below", bundle: .module),
                keywords: ["tab", "pane"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.shift, .option, .command]),
                category: .tab, symbol: "arrow.down.square.fill", surfaces: [.palette, .keyboard, .menu, .contextMenu],
                targets: [.tab], cliName: "tab move-to-pane-below", mainMenu: .file
            ),
            ActionDescriptor(
                id: "selectSurfaceByNumber",
                title: String(localized: "action.selectSurfaceByNumber", defaultValue: "Select Tab 1…9", bundle: .module),
                keywords: ["tab", "switch", "index"], defaultShortcut: Shortcut("1", modifiers: [.control]),
                shortcutFamily: .digits, category: .tab, symbol: "number.square", surfaces: [.keyboard],
                arguments: [CatalogArgument.indexNumber], targets: [.tab], cliName: "tab select-1-9"
            ),
            ActionDescriptor(
                id: "palette.goToTab",
                title: String(localized: "action.palette.goToTab", defaultValue: "Go to Tab…", bundle: .module),
                keywords: ["tab", "switch", "switcher", "surface"], category: .tab, symbol: "rectangle.stack",
                surfaces: [.palette], arguments: [CatalogArgument.tabTab], targets: [.tab], cliName: "tab go-to"
            ),
            ActionDescriptor(
                id: "palette.moveTabToNewWorkspace",
                title: String(localized: "action.palette.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace", bundle: .module),
                keywords: ["tab", "detach"], category: .tab, symbol: "rectangle.portrait.and.arrow.right",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab move-to-new-workspace"
            ),
            ActionDescriptor(
                id: "palette.toggleTabPin",
                title: String(localized: "action.palette.toggleTabPin", defaultValue: "Pin/Unpin Tab", bundle: .module),
                keywords: ["tab", "pin"], category: .tab, symbol: "pin.fill", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab pin-unpin"
            ),
            ActionDescriptor(
                id: "palette.toggleTabUnread",
                title: String(localized: "action.palette.toggleTabUnread", defaultValue: "Mark Tab as Unread", bundle: .module),
                keywords: ["tab", "unread"], category: .tab, symbol: "circle.fill", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab mark-as-unread"
            ),
            ActionDescriptor(
                id: "palette.toggleFullWidthTab",
                title: String(localized: "action.palette.toggleFullWidthTab", defaultValue: "Toggle Full Width Tab", bundle: .module),
                keywords: ["tab", "width"], category: .tab, symbol: "arrow.left.and.right",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab toggle-full-width"
            ),
            ActionDescriptor(
                id: "duplicateTab",
                title: String(localized: "action.duplicateTab", defaultValue: "Duplicate Tab", bundle: .module),
                keywords: ["tab", "copy", "clone"], category: .tab, symbol: "plus.square.on.square",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab duplicate"
            ),
            ActionDescriptor(
                id: "reloadTab",
                title: String(localized: "action.reloadTab", defaultValue: "Reload Tab", bundle: .module),
                keywords: ["tab", "refresh"], category: .tab, symbol: "arrow.clockwise", surfaces: [.contextMenu],
                targets: [.tab], cliName: "tab reload"
            ),
            ActionDescriptor(
                id: "toggleTabAudioMute",
                title: String(localized: "action.toggleTabAudioMute", defaultValue: "Mute/Unmute Tab", bundle: .module),
                keywords: ["tab", "audio", "sound"], category: .tab, symbol: "speaker.slash", surfaces: [.contextMenu],
                targets: [.tab], cliName: "tab mute-unmute"
            ),
            ActionDescriptor(
                id: "disconnectRemoteTab",
                title: String(localized: "action.disconnectRemoteTab", defaultValue: "Disconnect SSH Tab", bundle: .module),
                keywords: ["tab", "ssh", "remote"], category: .tab, symbol: "bolt.horizontal", surfaces: [.contextMenu],
                targets: [.tab], cliName: "tab disconnect-ssh"
            ),
            ActionDescriptor(
                id: "palette.copyIdentifiers",
                title: String(localized: "action.palette.copyIdentifiers", defaultValue: "Copy Identifiers", bundle: .module),
                keywords: ["id", "ref"], category: .tab, symbol: "number.circle", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab copy-identifiers"
            ),
            ActionDescriptor(
                id: "palette.copyPaneID",
                title: String(localized: "action.palette.copyPaneID", defaultValue: "Copy Pane ID", bundle: .module),
                keywords: ["id", "pane"], category: .tab, symbol: "doc.on.doc", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab copy-pane-id"
            ),
            ActionDescriptor(
                id: "palette.copyPaneLink",
                title: String(localized: "action.palette.copyPaneLink", defaultValue: "Copy Pane Link", bundle: .module),
                keywords: ["url", "pane"], category: .tab, symbol: "link", surfaces: [.palette, .contextMenu],
                targets: [.tab], cliName: "tab copy-pane-link"
            ),
            ActionDescriptor(
                id: "palette.copySurfaceID",
                title: String(localized: "action.palette.copySurfaceID", defaultValue: "Copy Tab ID", bundle: .module),
                keywords: ["id", "surface"], category: .tab, symbol: "doc.on.clipboard",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab copy-id"
            ),
            ActionDescriptor(
                id: "palette.copySurfaceLink",
                title: String(localized: "action.palette.copySurfaceLink", defaultValue: "Copy Tab Link", bundle: .module),
                keywords: ["url", "surface"], category: .tab, symbol: "link.badge.plus",
                surfaces: [.palette, .contextMenu], targets: [.tab], cliName: "tab copy-link"
            ),
            ActionDescriptor(
                id: "reopenClosedBrowserPanel",
                title: String(localized: "action.reopenClosedBrowserPanel", defaultValue: "Reopen Last Closed Tab", bundle: .module),
                keywords: ["undo", "restore"], defaultShortcut: Shortcut("t", modifiers: [.command, .shift]),
                category: .tab, symbol: "arrow.uturn.backward", surfaces: [.palette, .keyboard, .menu], targets: [.tab],
                cliName: "tab reopen-last-closed", mainMenu: .file
            ),
        ]
    }
}
