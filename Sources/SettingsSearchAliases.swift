enum SettingsSearchAliasIndex {
    static func sectionAliases(for target: SettingsNavigationTarget) -> String {
        switch target {
        case .account:
            return "auth authentication login logout sign in sign out email user profile team"
        case .app:
            return "general preferences prefs behavior chrome dock menubar menu bar status notifications sidebar telemetry"
        case .terminal:
            return "shell scrollback scrollbar scroll bar ghostty tty pty"
        case .sidebarAppearance:
            return "left rail navigation tint transparency opacity material color"
        case .automation:
            return "api cli control socket mcp agents hooks ports"
        case .browser:
            return "web webview address bar omnibar links urls embedded default browser"
        case .browserImport:
            return "chrome safari firefox brave edge arc bookmarks history cookies profiles"
        case .globalHotkey:
            return "system shortcut global keyboard show hide bring forward"
        case .keyboardShortcuts:
            return "keybinds key bindings hotkeys chords accelerators commands"
        case .workspaceColors:
            return "tab colors palette accent badge selected highlight"
        case .settingsJSON:
            return "configuration config file json jsonc dotfile ~/.config schema docs"
        case .reset:
            return "factory defaults restore clear preferences"
        }
    }

    static func aliases(target: SettingsNavigationTarget, idSuffix: String) -> String {
        let aliases = settingAliases["\(target.rawValue):\(idSuffix)"] ?? ""
        if target == .keyboardShortcuts, idSuffix == "shortcuts" {
            return "\(aliases) \(keyboardShortcutActionAliases)"
        }
        return aliases
    }

    private static let settingAliases: [String: String] = [
        "account:account": "auth authentication login logout signin sign-in signout sign-out email user profile stack team",
        "app:language": "app.language locale l10n localization translation japanese english ja en nihongo restart",
        "app:appearance": "app.appearance theme color scheme light mode dark mode system mode",
        "app:app-icon": "app.appIcon dock icon application icon app switcher alternate icon",
        "app:new-workspace-placement": "app.newWorkspacePlacement new tab insert position order top bottom end",
        "app:minimal-mode": "app.minimalMode minimal layout simple chrome compact titlebar controls",
        "app:keep-workspace-open": "app.keepWorkspaceOpenWhenClosingLastSurface cmd-w command-w close last pane surface keep tab workspace",
        "app:focus-pane-first-click": "app.focusPaneOnFirstClick click to focus focus follows mouse first click mouse activation",
        "app:preferred-editor": "app.preferredEditor editor open file code vscode visual studio zed sublime subl cursor",
        "app:terminal-config": "ghostty config configuration terminal settings preview merged file reload",
        "app:markdown-viewer": "app.openMarkdownInCmuxViewer md markdown mdx viewer preview readme",
        "app:reorder-notification": "app.reorderOnNotification notification reorder move workspace top unread sort",
        "app:dock-badge": "notifications.dockBadge badge dock unread count icon notifications red bubble",
        "app:menu-bar-only": "app.menuBarOnly menubar menu bar dockless hide dock app switcher cmd-tab command-tab",
        "app:show-menu-bar": "notifications.showInMenuBar menubar menu bar status item tray extra",
        "app:unread-pane-ring": "notifications.unreadPaneRing blue border unread ring notification pane outline",
        "app:pane-flash": "notifications.paneFlash flash blink highlight pane notification pulse",
        "app:desktop-notifications": "macos desktop notifications system settings permission alerts notify test",
        "app:notification-sound": "notifications.sound notifications.customSoundFilePath sound audio alert chime beep custom file wav mp3 caf aiff",
        "app:notification-command": "notifications.command shell command hook script env environment variable done agent",
        "app:telemetry": "app.sendAnonymousTelemetry analytics crash reports sentry posthog usage anonymous privacy",
        "app:warn-before-quit": "app.warnBeforeQuit quit confirmation command-q cmd-q exit close app",
        "app:rename-selects-name": "app.renameSelectsExistingName rename select all existing title command palette workspace name",
        "app:palette-search-all": "app.commandPaletteSearchesAllSurfaces command palette search all surfaces cmd-p terminal browser markdown",
        "app:hide-sidebar-details": "sidebar.hideAllDetails compact sidebar hide details only title minimal left rail",
        "app:sidebar-branch-layout": "sidebar.branchLayout git branch layout vertical inline cwd directory",
        "app:show-notification-message": "sidebar.showNotificationMessage latest message unread notification text sidebar",
        "app:show-branch-directory": "sidebar.showBranchDirectory git branch cwd path directory folder repo sidebar",
        "app:show-pull-requests": "sidebar.showPullRequests pr mr review github gitlab bitbucket pull request merge request",
        "app:open-pr-links": "sidebar.openPullRequestLinksInCmuxBrowser pr links github browser default external embedded",
        "app:open-port-links": "sidebar.openPortLinksInCmuxBrowser ports localhost links browser default external embedded",
        "app:show-ssh": "sidebar.showSSH remote host target ssh server",
        "app:show-ports": "sidebar.showPorts localhost port listener dev server url",
        "app:show-log": "sidebar.showLog log status latest message imperative",
        "app:show-progress": "sidebar.showProgress progress bar percent status set_progress",
        "app:show-metadata": "sidebar.showCustomMetadata metadata meta report_meta status custom block",
        "terminal:scrollbar": "terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui",
        "sidebarAppearance:match-terminal": "sidebarAppearance.matchTerminalBackground transparent background material terminal background sync",
        "sidebarAppearance:light-tint": "sidebarAppearance.lightModeTintColor light color sidebar tint hex daytime",
        "sidebarAppearance:dark-tint": "sidebarAppearance.darkModeTintColor dark color sidebar tint hex nighttime",
        "sidebarAppearance:tint-opacity": "sidebarAppearance.tintOpacity alpha transparency intensity blend",
        "sidebarAppearance:reset-tint": "restore default clear tint colors opacity",
        "automation:socket-mode": "automation.socketControlMode api socket unix domain control server auth allow password disabled",
        "automation:socket-password": "automation.socketPassword auth token credential secret password access key",
        "automation:claude-code": "automation.claudeCodeIntegration claude code hooks agent integration status notifications",
        "automation:claude-path": "automation.claudeBinaryPath claude binary executable path cli command custom",
        "automation:cursor": "automation.cursorIntegration cursor ide agent hooks notifications",
        "automation:gemini": "automation.geminiIntegration gemini cli google agent hooks notifications",
        "automation:port-base": "automation.portBase cmux_port start first base env environment variable",
        "automation:port-range": "automation.portRange cmux_port_end range size count env ports",
        "browser:enable-browser": "browser.enabled enable disable webview embedded browser tabs links",
        "browser:search-engine": "browser.defaultSearchEngine omnibar address bar google duckduckgo bing search provider",
        "browser:search-suggestions": "browser.showSearchSuggestions suggest autocomplete address bar search suggestions",
        "browser:theme": "browser.theme web page theme color scheme light dark system",
        "browser:terminal-links": "browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href",
        "browser:intercept-open": "browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept",
        "browser:host-whitelist": "browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser",
        "browser:external-patterns": "browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser",
        "browser:http-allowlist": "browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning",
        "browserImport:import-data": "chrome safari firefox brave edge arc bookmarks history cookies profiles migration",
        "browserImport:import-hint": "browser.showImportHintOnBlankTabs blank tab onboarding hint import prompt dismiss",
        "browser:react-grab": "browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component",
        "browser:history": "clear browser history visited pages suggestions omnibar",
        "globalHotkey:enable-hotkey": "global hotkey enable system wide show hide all windows",
        "globalHotkey:shortcut": "global hotkey shortcut recorder key command option control",
        "keyboardShortcuts:shortcut-chords": "tmux prefix ctrl-b control-b multi key sequence chord settings json",
        "keyboardShortcuts:show-hints": "shortcuts.showModifierHoldHints hold command ctrl key hints modifier overlay pills",
        "keyboardShortcuts:shortcuts": "hotkeys keybindings key bindings commands keyboard accelerators shortcuts settings json",
        "workspaceColors:indicator": "workspaceColors.indicatorStyle tab indicator active workspace style color stripe dot",
        "workspaceColors:selection": "workspaceColors.selectionColor selected workspace color highlight background active tab",
        "workspaceColors:badge": "workspaceColors.notificationBadgeColor unread notification badge color dot count",
        "workspaceColors:palette": "workspaceColors.colors workspace palette named colors custom color reset built-in",
        "settingsJSON:open-file": "open settings file json jsonc config editor ~/.config cmux preferences",
        "settingsJSON:documentation": "docs documentation schema reference settings json keys configuration",
        "reset:reset-all": "factory reset restore defaults clear preferences"
    ]

    private static var keyboardShortcutActionAliases: String {
        KeyboardShortcutSettings.Action.allCases.map(\.label).joined(separator: " ")
    }
}
