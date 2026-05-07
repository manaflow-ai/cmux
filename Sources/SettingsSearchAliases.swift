enum SettingsSearchAliasIndex {
    static func sectionAliases(for target: SettingsNavigationTarget) -> String {
        switch target {
        case .account:
            return localized("settings.search.alias.section.account", defaultValue: "auth authentication login logout sign in sign out email user profile team")
        case .app:
            return localized("settings.search.alias.section.app", defaultValue: "general preferences prefs behavior chrome dock menubar menu bar status notifications telemetry")
        case .terminal:
            return localized("settings.search.alias.section.terminal", defaultValue: "shell scrollback scrollbar scroll bar ghostty tty pty")
        case .sidebarAppearance:
            return localized("settings.search.alias.section.sidebarAppearance", defaultValue: "sidebar left rail navigation details branches badges material terminal background")
        case .betaFeatures:
            return localized("settings.search.alias.section.betaFeatures", defaultValue: "beta experimental unstable preview feed dock right sidebar")
        case .automation:
            return localized("settings.search.alias.section.automation", defaultValue: "api cli control socket mcp agents hooks ports")
        case .browser:
            return localized("settings.search.alias.section.browser", defaultValue: "web webview address bar omnibar links urls embedded default browser")
        case .browserImport:
            return localized("settings.search.alias.section.browserImport", defaultValue: "chrome safari firefox brave edge arc bookmarks history cookies profiles")
        case .globalHotkey:
            return localized("settings.search.alias.section.globalHotkey", defaultValue: "system shortcut global keyboard show hide bring forward")
        case .keyboardShortcuts:
            return localized("settings.search.alias.section.keyboardShortcuts", defaultValue: "keybinds key bindings hotkeys chords accelerators commands")
        case .workspaceColors:
            return localized("settings.search.alias.section.workspaceColors", defaultValue: "tab colors palette accent badge selected highlight")
        case .settingsJSON:
            return localized("settings.search.alias.section.settingsJSON", defaultValue: "configuration config file json jsonc dotfile ~/.config schema docs")
        case .reset:
            return localized("settings.search.alias.section.reset", defaultValue: "factory defaults restore clear preferences")
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
        "account:account": localized("settings.search.alias.setting.account.account", defaultValue: "auth authentication login logout signin sign-in signout sign-out email user profile stack team"),
        "app:language": localized("settings.search.alias.setting.app.language", defaultValue: "app.language locale l10n localization translation japanese english ja en nihongo restart"),
        "app:appearance": localized("settings.search.alias.setting.app.appearance", defaultValue: "app.appearance theme color scheme light mode dark mode system mode"),
        "app:app-icon": localized("settings.search.alias.setting.app.app-icon", defaultValue: "app.appIcon dock icon application icon app switcher alternate icon"),
        "app:new-workspace-placement": localized("settings.search.alias.setting.app.new-workspace-placement", defaultValue: "app.newWorkspacePlacement new tab insert position order top bottom end"),
        "app:minimal-mode": localized("settings.search.alias.setting.app.minimal-mode", defaultValue: "app.minimalMode minimal layout simple chrome compact titlebar controls"),
        "app:keep-workspace-open": localized("settings.search.alias.setting.app.keep-workspace-open", defaultValue: "app.keepWorkspaceOpenWhenClosingLastSurface cmd-w command-w close last pane surface keep tab workspace"),
        "app:focus-pane-first-click": localized("settings.search.alias.setting.app.focus-pane-first-click", defaultValue: "app.focusPaneOnFirstClick click to focus focus follows mouse first click mouse activation"),
        "app:preferred-editor": localized("settings.search.alias.setting.app.preferred-editor", defaultValue: "app.preferredEditor editor open file code vscode visual studio zed sublime subl cursor"),
        "app:terminal-config": localized("settings.search.alias.setting.app.terminal-config", defaultValue: "ghostty config configuration terminal settings preview merged file reload"),
        "app:markdown-viewer": localized("settings.search.alias.setting.app.markdown-viewer", defaultValue: "app.openMarkdownInCmuxViewer md markdown mdx viewer preview readme"),
        "app:reorder-notification": localized("settings.search.alias.setting.app.reorder-notification", defaultValue: "app.reorderOnNotification notification reorder move workspace top unread sort"),
        "app:dock-badge": localized("settings.search.alias.setting.app.dock-badge", defaultValue: "notifications.dockBadge badge dock unread count icon notifications red bubble"),
        "app:menu-bar-only": localized("settings.search.alias.setting.app.menu-bar-only", defaultValue: "app.menuBarOnly menubar menu bar dockless hide dock app switcher cmd-tab command-tab"),
        "app:show-menu-bar": localized("settings.search.alias.setting.app.show-menu-bar", defaultValue: "notifications.showInMenuBar menubar menu bar status item tray extra"),
        "app:unread-pane-ring": localized("settings.search.alias.setting.app.unread-pane-ring", defaultValue: "notifications.unreadPaneRing blue border unread ring notification pane outline"),
        "app:pane-flash": localized("settings.search.alias.setting.app.pane-flash", defaultValue: "notifications.paneFlash flash blink highlight pane notification pulse"),
        "app:desktop-notifications": localized("settings.search.alias.setting.app.desktop-notifications", defaultValue: "macos desktop notifications system settings permission alerts notify test"),
        "app:notification-sound": localized("settings.search.alias.setting.app.notification-sound", defaultValue: "notifications.sound notifications.customSoundFilePath sound audio alert chime beep custom file wav mp3 caf aiff"),
        "app:notification-command": localized("settings.search.alias.setting.app.notification-command", defaultValue: "notifications.command shell command hook script env environment variable done agent"),
        "app:telemetry": localized("settings.search.alias.setting.app.telemetry", defaultValue: "app.sendAnonymousTelemetry analytics crash reports sentry posthog usage anonymous privacy"),
        "app:warn-before-quit": localized("settings.search.alias.setting.app.warn-before-quit", defaultValue: "app.warnBeforeQuit quit confirmation command-q cmd-q exit close app"),
        "app:rename-selects-name": localized("settings.search.alias.setting.app.rename-selects-name", defaultValue: "app.renameSelectsExistingName rename select all existing title command palette workspace name"),
        "app:palette-search-all": localized("settings.search.alias.setting.app.palette-search-all", defaultValue: "app.commandPaletteSearchesAllSurfaces command palette search all surfaces cmd-p terminal browser markdown"),
        "terminal:scrollbar": localized("settings.search.alias.setting.terminal.scrollbar", defaultValue: "terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui"),
        "sidebarAppearance:match-terminal": localized("settings.search.alias.setting.sidebarAppearance.match-terminal", defaultValue: "sidebarAppearance.matchTerminalBackground transparent background material terminal background sync"),
        "sidebarAppearance:hide-sidebar-details": localized("settings.search.alias.setting.app.hide-sidebar-details", defaultValue: "sidebar.hideAllDetails compact sidebar hide details only title minimal left rail"),
        "sidebarAppearance:sidebar-branch-layout": localized("settings.search.alias.setting.app.sidebar-branch-layout", defaultValue: "sidebar.branchLayout git branch layout vertical inline cwd directory"),
        "sidebarAppearance:show-notification-message": localized("settings.search.alias.setting.app.show-notification-message", defaultValue: "sidebar.showNotificationMessage latest message unread notification text sidebar"),
        "sidebarAppearance:show-branch-directory": localized("settings.search.alias.setting.app.show-branch-directory", defaultValue: "sidebar.showBranchDirectory git branch cwd path directory folder repo sidebar"),
        "sidebarAppearance:show-pull-requests": localized("settings.search.alias.setting.app.show-pull-requests", defaultValue: "sidebar.showPullRequests pr mr review github gitlab bitbucket pull request merge request"),
        "sidebarAppearance:open-pr-links": localized("settings.search.alias.setting.app.open-pr-links", defaultValue: "sidebar.openPullRequestLinksInCmuxBrowser pr links github browser default external embedded"),
        "sidebarAppearance:open-port-links": localized("settings.search.alias.setting.app.open-port-links", defaultValue: "sidebar.openPortLinksInCmuxBrowser ports localhost links browser default external embedded"),
        "sidebarAppearance:show-ssh": localized("settings.search.alias.setting.app.show-ssh", defaultValue: "sidebar.showSSH remote host target ssh server"),
        "sidebarAppearance:show-ports": localized("settings.search.alias.setting.app.show-ports", defaultValue: "sidebar.showPorts localhost port listener dev server url"),
        "sidebarAppearance:show-log": localized("settings.search.alias.setting.app.show-log", defaultValue: "sidebar.showLog log status latest message imperative"),
        "sidebarAppearance:show-progress": localized("settings.search.alias.setting.app.show-progress", defaultValue: "sidebar.showProgress progress bar percent status set_progress"),
        "sidebarAppearance:show-metadata": localized("settings.search.alias.setting.app.show-metadata", defaultValue: "sidebar.showCustomMetadata metadata meta report_meta status custom block"),
        "betaFeatures:feed": localized("settings.search.alias.setting.betaFeatures.feed", defaultValue: "feed right sidebar agent decisions permissions questions approval beta unstable"),
        "betaFeatures:dock": localized("settings.search.alias.setting.betaFeatures.dock", defaultValue: "dock right sidebar terminal controls tui beta unstable"),
        "automation:socket-mode": localized("settings.search.alias.setting.automation.socket-mode", defaultValue: "automation.socketControlMode api socket unix domain control server auth allow password disabled"),
        "automation:socket-password": localized("settings.search.alias.setting.automation.socket-password", defaultValue: "automation.socketPassword auth token credential secret password access key"),
        "automation:claude-code": localized("settings.search.alias.setting.automation.claude-code", defaultValue: "automation.claudeCodeIntegration claude code hooks agent integration status notifications"),
        "automation:claude-path": localized("settings.search.alias.setting.automation.claude-path", defaultValue: "automation.claudeBinaryPath claude binary executable path cli command custom"),
        "automation:cursor": localized("settings.search.alias.setting.automation.cursor", defaultValue: "automation.cursorIntegration cursor ide agent hooks notifications"),
        "automation:gemini": localized("settings.search.alias.setting.automation.gemini", defaultValue: "automation.geminiIntegration gemini cli google agent hooks notifications"),
        "automation:port-base": localized("settings.search.alias.setting.automation.port-base", defaultValue: "automation.portBase cmux_port start first base env environment variable"),
        "automation:port-range": localized("settings.search.alias.setting.automation.port-range", defaultValue: "automation.portRange cmux_port_end range size count env ports"),
        "browser:enable-browser": localized("settings.search.alias.setting.browser.enable-browser", defaultValue: "browser.enabled enable disable webview embedded browser tabs links"),
        "browser:search-engine": localized("settings.search.alias.setting.browser.search-engine", defaultValue: "browser.defaultSearchEngine omnibar address bar google duckduckgo bing search provider"),
        "browser:search-suggestions": localized("settings.search.alias.setting.browser.search-suggestions", defaultValue: "browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
        "browser:theme": localized("settings.search.alias.setting.browser.theme", defaultValue: "browser.theme web page theme color scheme light dark system"),
        "browser:terminal-links": localized("settings.search.alias.setting.browser.terminal-links", defaultValue: "browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href"),
        "browser:intercept-open": localized("settings.search.alias.setting.browser.intercept-open", defaultValue: "browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept"),
        "browser:host-whitelist": localized("settings.search.alias.setting.browser.host-whitelist", defaultValue: "browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser"),
        "browser:external-patterns": localized("settings.search.alias.setting.browser.external-patterns", defaultValue: "browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser"),
        "browser:http-allowlist": localized("settings.search.alias.setting.browser.http-allowlist", defaultValue: "browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning"),
        "browserImport:import-data": localized("settings.search.alias.setting.browserImport.import-data", defaultValue: "chrome safari firefox brave edge arc bookmarks history cookies profiles migration"),
        "browserImport:import-hint": localized("settings.search.alias.setting.browserImport.import-hint", defaultValue: "browser.showImportHintOnBlankTabs blank tab onboarding hint import prompt dismiss"),
        "browser:react-grab": localized("settings.search.alias.setting.browser.react-grab", defaultValue: "browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component"),
        "browser:history": localized("settings.search.alias.setting.browser.history", defaultValue: "clear browser history visited pages suggestions omnibar"),
        "globalHotkey:enable-hotkey": localized("settings.search.alias.setting.globalHotkey.enable-hotkey", defaultValue: "global hotkey enable system wide show hide all windows"),
        "globalHotkey:shortcut": localized("settings.search.alias.setting.globalHotkey.shortcut", defaultValue: "global hotkey shortcut recorder key command option control"),
        "keyboardShortcuts:shortcut-chords": localized("settings.search.alias.setting.keyboardShortcuts.shortcut-chords", defaultValue: "tmux prefix ctrl-b control-b multi key sequence chord cmux json"),
        "keyboardShortcuts:show-hints": localized("settings.search.alias.setting.keyboardShortcuts.show-hints", defaultValue: "shortcuts.showModifierHoldHints hold command ctrl key hints modifier overlay pills"),
        "keyboardShortcuts:shortcuts": localized("settings.search.alias.setting.keyboardShortcuts.shortcuts", defaultValue: "hotkeys keybindings key bindings commands keyboard accelerators shortcuts cmux json"),
        "workspaceColors:indicator": localized("settings.search.alias.setting.workspaceColors.indicator", defaultValue: "workspaceColors.indicatorStyle tab indicator active workspace style color stripe dot"),
        "workspaceColors:selection": localized("settings.search.alias.setting.workspaceColors.selection", defaultValue: "workspaceColors.selectionColor selected workspace color highlight background active tab"),
        "workspaceColors:badge": localized("settings.search.alias.setting.workspaceColors.badge", defaultValue: "workspaceColors.notificationBadgeColor unread notification badge color dot count"),
        "workspaceColors:palette": localized("settings.search.alias.setting.workspaceColors.palette", defaultValue: "workspaceColors.colors workspace palette named colors custom color reset built-in"),
        "settingsJSON:open-file": localized("settings.search.alias.setting.settingsJSON.open-file", defaultValue: "open config file json jsonc config editor ~/.config cmux preferences"),
        "settingsJSON:documentation": localized("settings.search.alias.setting.settingsJSON.documentation", defaultValue: "docs documentation schema reference cmux json keys configuration"),
        "reset:reset-all": localized("settings.search.alias.setting.reset.reset-all", defaultValue: "factory reset restore defaults clear preferences")
    ]

    private static var keyboardShortcutActionAliases: String {
        KeyboardShortcutSettings.Action.allCases.map(\.label).joined(separator: " ")
    }

    private static func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }
}
