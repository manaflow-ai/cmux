import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// The cmux-shipped curated search entries.
    ///
    /// Ported from the legacy `SettingsSearchIndex.settingEntries` +
    /// `SettingsSearchAliasIndex.settingAliases` tables in
    /// `Sources/SettingsNavigation.swift` and
    /// `Sources/SettingsSearchAliases.swift`. Roughly one row per
    /// high-signal setting; the surface area is meant to mirror what
    /// users actually search for, not the full catalog. Catalog keys
    /// not present here still fall back to a dotted-id index entry in
    /// ``SettingsSearchIndex``.
    ///
    /// Strings are English-only until the package ships an
    /// `xcstrings` catalog. Tests and hosts that want a different set
    /// of entries pass their own array via
    /// ``SettingsSearchIndex/init(catalog:curatedEntries:)``.
    public static var cmuxDefault: [CuratedSettingEntry] {
        [
            // Account / integrations
            .init(section: .account, id: "account", title: "Account", synonyms: "auth authentication login logout signin sign-in signout sign-out email user profile stack team"),
            .init(section: .account, id: "claude-code", title: "Claude Code Integration", synonyms: "automation.claudeCodeIntegration claude code hooks agent integration status notifications"),
            .init(section: .account, id: "claude-path", title: "Claude Binary Path", synonyms: "automation.claudeBinaryPath claude binary executable path cli command custom"),
            .init(section: .account, id: "ripgrep-path", title: "Ripgrep Binary Path", synonyms: "ripgrep rg binary executable path search find nix custom"),
            .init(section: .account, id: "subagent-notifications", title: "Suppress Subagent Notifications", synonyms: "subagent nested child agent codex claude hooks notifications"),
            .init(section: .account, id: "cursor", title: "Cursor Integration", synonyms: "cursor ide agent hooks notifications"),
            .init(section: .account, id: "gemini", title: "Gemini CLI Integration", synonyms: "gemini cli google agent hooks notifications"),

            // App
            .init(section: .app, id: "language", title: "Language", synonyms: "app.language locale l10n localization translation japanese english ja en nihongo restart"),
            .init(section: .app, id: "appearance", title: "Appearance", synonyms: "app.appearance theme color scheme light mode dark mode system mode"),
            .init(section: .app, id: "app-icon", title: "App Icon", synonyms: "app.appIcon dock icon application icon app switcher alternate icon"),
            .init(section: .app, id: "new-workspace-placement", title: "New Workspace Placement", synonyms: "app.newWorkspacePlacement new tab insert position order top bottom end"),
            .init(section: .app, id: "workspace-inherit-working-directory", title: "Inherit Workspace Working Directory", synonyms: "workspace cwd directory inherit current focused working-directory"),
            .init(section: .app, id: "minimal-mode", title: "Workspace Presentation Mode", synonyms: "presentation compact chrome layout simple titlebar controls"),
            .init(section: .app, id: "keep-workspace-open", title: "Keep Workspace Open After Last Pane Closes", synonyms: "close last pane surface keep tab workspace"),
            .init(section: .app, id: "focus-pane-first-click", title: "Focus Pane on First Click", synonyms: "click to focus focus follows mouse first click mouse activation"),
            .init(section: .app, id: "file-drops", title: "File Drops Default Behavior", synonyms: "drag drop files finder path text terminal editor split preview shift"),
            .init(section: .app, id: "preferred-editor", title: "Preferred Editor Command", synonyms: "editor open file code vscode visual studio zed sublime subl cursor"),
            .init(section: .app, id: "supported-file-previews", title: "Open Supported Files in cmux", synonyms: "cmd click file preview pdf image video audio quicklook quick look editor external"),
            .init(section: .app, id: "markdown-viewer", title: "Open Markdown in cmux Viewer", synonyms: "md markdown mdx viewer preview readme"),
            .init(section: .app, id: "imessage-mode", title: "iMessage Mode", synonyms: "imessage message messages chat prompt prompts submitted texting reorder move workspace top agent send"),
            .init(section: .app, id: "reorder-notification", title: "Reorder Workspaces on Notification", synonyms: "notification reorder move workspace top unread sort"),
            .init(section: .app, id: "menu-bar-only", title: "Menu Bar Only", synonyms: "menubar menu bar dockless hide dock app switcher cmd-tab command-tab"),
            .init(section: .app, id: "telemetry", title: "Send Anonymous Telemetry", synonyms: "analytics crash reports sentry posthog usage anonymous privacy"),
            .init(section: .app, id: "warn-before-quit", title: "Warn Before Quitting", synonyms: "quit confirmation command-q cmd-q exit close app"),
            .init(section: .app, id: "warn-before-closing-tab", title: "Warn Before Closing Tab", synonyms: "close tab confirmation command-w cmd-w terminal surface"),
            .init(section: .app, id: "warn-before-closing-tab-x-button", title: "Warn Before Closing Tab via X Button", synonyms: "x button close tab confirmation terminal surface"),
            .init(section: .app, id: "hide-tab-close-button", title: "Hide Tab Close Button", synonyms: "hide x button close tab terminal surface"),
            .init(section: .app, id: "rename-selects-name", title: "Rename Selects Existing Name", synonyms: "rename select all existing title command palette workspace name"),
            .init(section: .app, id: "palette-search-all", title: "Command Palette Searches All Surfaces", synonyms: "command palette search all surfaces cmd-p terminal browser markdown"),
            .init(section: .app, id: "dock-badge", title: "Dock Badge", synonyms: "notifications.dockBadge badge dock unread count icon notifications red bubble"),
            .init(section: .app, id: "show-menu-bar", title: "Show Menu Bar Extra", synonyms: "menubar menu bar status item tray extra"),
            .init(section: .app, id: "unread-pane-ring", title: "Unread Pane Ring", synonyms: "notifications.unreadPaneRing blue border unread ring notification pane outline"),
            .init(section: .app, id: "pane-flash", title: "Pane Flash", synonyms: "notifications.paneFlash flash blink highlight pane notification pulse"),
            .init(section: .app, id: "notification-sound", title: "Notification Sound", synonyms: "notifications.sound sound audio alert chime beep custom file wav mp3 caf aiff"),
            .init(section: .app, id: "notification-command", title: "Notification Command", synonyms: "notifications.command shell command hook script env environment variable done agent"),

            // Terminal
            .init(section: .terminal, id: "scrollbar", title: "Show Terminal Scroll Bar", synonyms: "terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui"),
            .init(section: .terminal, id: "copy-on-select", title: "Copy on Selection", synonyms: "terminal.copyOnSelect copy on selection select clipboard mouse double click triple click iterm"),
            .init(section: .terminal, id: "agent-auto-resume", title: "Resume Agent Sessions on Reopen", synonyms: "terminal.autoResumeAgentSessions auto resume restore reopen relaunch quit sessions agents claude code codex opencode rovo dev rovodev toggle"),
            .init(section: .terminal, id: "agent-hibernation", title: "Agent Hibernation", synonyms: "terminal.agentHibernation idle hibernate suspend background agents claude code codex opencode live terminals"),
            .init(section: .terminal, id: "resume-commands", title: "Resume Commands", synonyms: "surface resume command approvals prefixes auto restore prompt manual tmux hibernation"),

            // TextBox
            .init(section: .textBox, id: "show-textbox-new-terminals", title: "Show TextBox on New Terminals", synonyms: "terminal.showTextBoxOnNewTerminals show textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "focus-textbox-new-terminals", title: "Focus TextBox on New Terminals", synonyms: "terminal.focusTextBoxOnNewTerminals focus textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "textbox-max-lines", title: "TextBox Max Lines", synonyms: "terminal.textBoxMaxLines textbox text box rich input prompt max height lines grow scroll beta"),

            // Sidebar appearance + sidebar workspace row details
            .init(section: .sidebarAppearance, id: "match-terminal", title: "Match Terminal Background", synonyms: "sidebarAppearance.matchTerminalBackground transparent background material terminal background sync"),
            .init(section: .sidebarAppearance, id: "hide-sidebar-details", title: "Hide All Sidebar Details", synonyms: "sidebar.hideAllDetails compact sidebar hide details only title minimal left rail"),
            .init(section: .sidebarAppearance, id: "wrap-workspace-titles", title: "Wrap Workspace Titles in Sidebar", synonyms: "sidebar.wrapWorkspaceTitles workspace title wrap multiline pr pull request"),
            .init(section: .sidebarAppearance, id: "show-workspace-description", title: "Show Workspace Description in Sidebar", synonyms: "sidebar.showWorkspaceDescription workspace description notes markdown sidebar"),
            .init(section: .sidebarAppearance, id: "sidebar-branch-layout", title: "Sidebar Branch Layout", synonyms: "sidebar.branchVerticalLayout git branch layout vertical inline cwd directory"),
            .init(section: .sidebarAppearance, id: "stack-branch-directory", title: "Stack Branch and Directory", synonyms: "sidebar.stackBranchDirectory git branch directory cwd path stack stacked separate lines two rows"),
            .init(section: .sidebarAppearance, id: "path-last-segment-only", title: "Truncate Path From Start", synonyms: "sidebar.pathLastSegmentOnly cwd path directory last segment basename short truncate folder repo"),
            .init(section: .sidebarAppearance, id: "show-notification-message", title: "Show Notification Message in Sidebar", synonyms: "sidebar.showNotificationMessage latest message unread notification text sidebar"),
            .init(section: .sidebarAppearance, id: "show-branch-directory", title: "Show Branch + Directory in Sidebar", synonyms: "sidebar.showBranchDirectory git branch cwd path directory folder repo sidebar"),
            .init(section: .sidebarAppearance, id: "show-pull-requests", title: "Show Pull Requests in Sidebar", synonyms: "sidebar.showPullRequests pr mr review github gitlab bitbucket pull request merge request"),
            .init(section: .sidebarAppearance, id: "watch-git-status", title: "Watch Git Status in Sidebar", synonyms: "sidebar.watchGitStatus git status branch watcher index lock"),
            .init(section: .sidebarAppearance, id: "make-pr-clickable", title: "Make Sidebar PR Clickable", synonyms: "sidebar.makePullRequestsClickable clickable pull requests pr mr reviews links select workspace row"),
            .init(section: .sidebarAppearance, id: "open-pr-links", title: "Open Sidebar PR Links in cmux Browser", synonyms: "sidebar.openPullRequestLinksInCmuxBrowser pr links github browser default external embedded"),
            .init(section: .sidebarAppearance, id: "open-port-links", title: "Open Sidebar Port Links in cmux Browser", synonyms: "sidebar.openPortLinksInCmuxBrowser ports localhost links browser default external embedded"),
            .init(section: .sidebarAppearance, id: "show-ssh", title: "Show SSH in Sidebar", synonyms: "sidebar.showSSH remote host target ssh server"),
            .init(section: .sidebarAppearance, id: "show-ports", title: "Show Listening Ports in Sidebar", synonyms: "sidebar.showPorts localhost port listener dev server url"),
            .init(section: .sidebarAppearance, id: "show-log", title: "Show Latest Log in Sidebar", synonyms: "sidebar.showLog log status latest message imperative"),
            .init(section: .sidebarAppearance, id: "show-progress", title: "Show Progress in Sidebar", synonyms: "sidebar.showProgress progress bar percent status set_progress"),
            .init(section: .sidebarAppearance, id: "show-metadata", title: "Show Custom Metadata in Sidebar", synonyms: "sidebar.showCustomMetadata metadata meta report_meta status custom block"),

            // Beta
            .init(section: .betaFeatures, id: "dock", title: "Right-Sidebar Dock (Beta)", synonyms: "dock right sidebar terminal controls tui beta unstable"),

            // Automation
            .init(section: .automation, id: "socket-mode", title: "Socket Control Mode", synonyms: "automation.socketControlMode api socket unix domain control server auth allow password disabled"),
            .init(section: .automation, id: "socket-password", title: "Socket Password", synonyms: "automation.socketPassword auth token credential secret password access key"),
            .init(section: .automation, id: "port-base", title: "Port Base", synonyms: "automation.portBase cmux_port start first base env environment variable"),
            .init(section: .automation, id: "port-range", title: "Port Range Size", synonyms: "automation.portRange cmux_port_end range size count env ports"),

            // Browser
            .init(section: .browser, id: "enable-browser", title: "Disable cmux Browser", synonyms: "browser.disabled enable disable webview embedded browser tabs links"),
            .init(section: .browser, id: "search-engine", title: "Default Search Engine", synonyms: "browser.defaultSearchEngine omnibar address bar google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider"),
            .init(section: .browser, id: "search-suggestions", title: "Show Search Suggestions", synonyms: "browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
            .init(section: .browser, id: "theme", title: "Browser Theme", synonyms: "browser.theme web page theme color scheme light dark system"),
            .init(section: .browser, id: "hidden-webview-discard", title: "Discard Hidden Browser WebViews", synonyms: "browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"),
            .init(section: .browser, id: "hidden-webview-discard-delay", title: "Hidden WebView Discard Delay", synonyms: "browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"),
            .init(section: .browser, id: "terminal-links", title: "Open Terminal Links in cmux Browser", synonyms: "browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href"),
            .init(section: .browser, id: "intercept-open", title: "Intercept open http(s) in Terminal", synonyms: "browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept"),
            .init(section: .browser, id: "host-whitelist", title: "Hosts to Open in Embedded Browser", synonyms: "browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser"),
            .init(section: .browser, id: "external-patterns", title: "URLs to Always Open Externally", synonyms: "browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser"),
            .init(section: .browser, id: "http-allowlist", title: "HTTP Hosts Allowed in Embedded Browser", synonyms: "browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning"),
            .init(section: .browser, id: "react-grab", title: "React Grab Version", synonyms: "browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component"),

            // Browser import
            .init(section: .browserImport, id: "import-data", title: "Import Browser Data", synonyms: "chrome safari firefox brave edge arc bookmarks history cookies profiles migration"),
            .init(section: .browserImport, id: "import-hint", title: "Show Import Hint on Blank Tabs", synonyms: "browser.showImportHintOnBlankTabs blank tab onboarding hint import prompt dismiss"),

            // Global hotkey
            .init(section: .globalHotkey, id: "enable-hotkey", title: "Enable System-Wide Hotkey", synonyms: "app.systemWideHotkeyEnabled global hotkey enable system wide show hide all windows"),
            .init(section: .globalHotkey, id: "shortcut", title: "Global Hotkey", synonyms: "global hotkey shortcut recorder key command option control"),

            // Keyboard shortcuts
            .init(section: .keyboardShortcuts, id: "shortcuts", title: "Keyboard Shortcuts", synonyms: "shortcuts.bindings hotkeys keybindings key bindings commands keyboard accelerators chords cmux json"),
            .init(section: .keyboardShortcuts, id: "shortcut-chords", title: "Shortcut Chords", synonyms: "tmux prefix ctrl-b control-b multi key sequence chord cmux json"),
            .init(section: .keyboardShortcuts, id: "reset-defaults", title: "Reset Default Shortcuts", synonyms: "reset restore default defaults built in builtin shortcuts hotkeys keybindings commands"),

            // Workspace colors
            .init(section: .workspaceColors, id: "indicator", title: "Workspace Color Indicator", synonyms: "workspaceColors.indicatorStyle tab indicator active workspace style color stripe dot"),
            .init(section: .workspaceColors, id: "selection", title: "Selection Highlight", synonyms: "workspaceColors.selectionColor selected workspace color highlight background active tab"),
            .init(section: .workspaceColors, id: "badge", title: "Notification Badge Color", synonyms: "workspaceColors.notificationBadgeColor unread notification badge color dot count"),

            // cmux.json
            .init(section: .settingsJSON, id: "open-file", title: "Open Config File", synonyms: "open config file json jsonc config editor ~/.config cmux preferences"),
            .init(section: .settingsJSON, id: "documentation", title: "Configuration Documentation", synonyms: "docs documentation schema reference cmux json keys configuration"),

            // Reset
            .init(section: .reset, id: "reset-all", title: "Reset All Settings", synonyms: "factory reset restore defaults clear preferences"),
        ]
    }
}
