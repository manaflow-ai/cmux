import CmuxSettings
import Foundation

extension Array where Element == CuratedSettingEntry {
    /// The cmux-shipped curated search entries.
    ///
    /// Ported from the legacy `SettingsSearchIndex.settingEntries` +
    /// `SettingsSearchAliasIndex.settingAliases` tables in
    /// `Sources/SettingsNavigation.swift` and
    /// `Sources/SettingsSearchAliases.swift`. Roughly one row per
    /// high-signal setting; the surface area is meant to mirror visible
    /// rows users actually search for.
    ///
    /// Most strings are English-only until the package ships an
    /// `xcstrings` catalog; newer entries use the same localized
    /// strings as their rows when available. Tests and hosts that want
    /// a different set of entries pass their own array via
    /// ``SettingsSearchIndex/init(catalog:curatedEntries:)``.
    public static var cmuxDefault: [CuratedSettingEntry] {
        [
            // Account / integrations
            .init(section: .account, id: "account", title: "Account", synonyms: "auth authentication login logout signin sign-in signout sign-out email user profile stack team"),
            .init(section: .automation, id: "claude-code", title: "Claude Code Integration", synonyms: "automation.claudeCodeIntegration claude code hooks agent integration status notifications"),
            .init(section: .automation, id: "claude-path", title: "Claude Binary Path", synonyms: "automation.claudeBinaryPath claude binary executable path cli command custom"),
            .init(section: .automation, id: "ripgrep-path", title: "Ripgrep Binary Path", synonyms: "automation.ripgrepBinaryPath ripgrep rg binary executable path search find nix custom"),
            .init(section: .automation, id: "subagent-notifications", title: "Suppress Subagent Notifications", synonyms: "automation.suppressSubagentNotifications subagent nested child agent codex claude hooks notifications"),
            .init(section: .automation, id: "cursor", title: "Cursor Integration", synonyms: "automation.cursorIntegration cursor ide agent hooks notifications"),
            .init(section: .automation, id: "gemini", title: "Gemini CLI Integration", synonyms: "automation.geminiIntegration gemini cli google agent hooks notifications"),

            // App
            .init(section: .app, id: "language", title: "Language", synonyms: "app.language locale l10n localization translation japanese english ja en nihongo restart"),
            .init(section: .app, id: "appearance", title: "Appearance", synonyms: "app.appearance theme color scheme light mode dark mode system mode"),
            .init(section: .app, id: "app-icon", title: "App Icon", synonyms: "app.appIcon dock icon application icon app switcher alternate icon"),
            .init(section: .app, id: "new-workspace-placement", title: "New Workspace Placement", synonyms: "app.newWorkspacePlacement new tab insert position order top bottom end"),
            .init(section: .app, id: "workspace-inherit-working-directory", title: "Inherit Workspace Working Directory", synonyms: "app.workspaceInheritWorkingDirectory workspace cwd directory inherit current focused working-directory"),
            .init(section: .app, id: "minimal-mode", title: "Minimal Mode", synonyms: "app.minimalMode presentation compact chrome layout simple titlebar controls"),
            .init(section: .app, id: "keep-workspace-open", title: "Keep Workspace Open When Closing Last Surface", synonyms: "app.keepWorkspaceOpenWhenClosingLastSurface close last pane surface keep tab workspace"),
            .init(section: .app, id: "focus-pane-first-click", title: "Focus Pane on First Click", synonyms: "app.focusPaneOnFirstClick click to focus focus follows mouse first click mouse activation"),
            .init(section: .app, id: "file-drops", title: "File Drops", synonyms: "drag drop files finder path text terminal editor split preview shift"),
            .init(section: .app, id: "preferred-editor", title: "Open Files With", synonyms: "app.preferredEditor editor open file code vscode visual studio zed sublime subl cursor"),
            .init(section: .app, id: "supported-file-previews", title: "Open Supported Files in cmux", synonyms: "app.openSupportedFilesInCmux cmd click file preview pdf image video audio quicklook quick look editor external"),
            .init(section: .app, id: "markdown-viewer", title: "Open Markdown in cmux Viewer", synonyms: "app.openMarkdownInCmuxViewer md markdown mdx viewer preview readme"),
            .init(section: .app, id: "file-editor-word-wrap", title: "File Editor Word Wrap", synonyms: "fileEditor.wordWrap file editor word wrap soft wrap reflow lines text horizontal scroll preview"),
            .init(section: .app, id: "terminal-config", title: "Terminal Config", synonyms: "ghostty config merged generated preview terminal configuration window open config macos-option-as-alt option as alt left option right option alt key meta"),
            .init(section: .app, id: "global-font-magnification", title: String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"), synonyms: "app.globalFontMagnification global font magnification scale text zoom terminals tabs chrome bigger smaller accessibility"),
            .init(section: .app, id: "imessage-mode", title: "iMessage Mode", synonyms: "app.iMessageMode imessage message messages chat prompt prompts submitted texting reorder move workspace top agent send"),
            .init(section: .app, id: "reorder-notification", title: "Reorder on Notification", synonyms: "app.reorderOnNotification notification reorder move workspace top unread sort"),
            .init(section: .app, id: "menu-bar-only", title: "Menu Bar Only", synonyms: "app.menuBarOnly menubar menu bar dockless hide dock app switcher cmd-tab command-tab"),
            .init(section: .app, id: "telemetry", title: "Send anonymous telemetry", synonyms: "app.sendAnonymousTelemetry analytics crash reports sentry posthog usage anonymous privacy"),
            .init(section: .app, id: "warn-before-quit", title: "Warn Before Quit", synonyms: "app.confirmQuit quit confirmation command-q cmd-q exit close app"),
            .init(section: .app, id: "warn-before-closing-tab", title: "Warn Before Closing Tab", synonyms: "app.warnBeforeClosingTab close tab confirmation command-w cmd-w terminal surface"),
            .init(section: .app, id: "warn-before-closing-tab-x-button", title: "Warn Before Tab Close Button", synonyms: "app.warnBeforeClosingTabXButton x button close tab confirmation terminal surface"),
            .init(section: .app, id: "hide-tab-close-button", title: "Hide Tab Close Button", synonyms: "app.hideTabCloseButton hide x button close tab terminal surface"),
            .init(section: .app, id: "rename-selects-name", title: "Rename Selects Existing Name", synonyms: "app.renameSelectsExistingName rename select all existing title command palette workspace name"),
            .init(section: .app, id: "palette-search-all", title: "Command Palette Searches All Surfaces", synonyms: "app.commandPaletteSearchesAllSurfaces command palette search all surfaces cmd-p terminal browser markdown"),
            .init(
                section: .app,
                id: "canvas-pane-gap",
                title: String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap"),
                paths: ["canvas.paneGap"],
                synonyms: "canvas.paneGap canvas pane gap spacing freeform layout panes snapping tidy distribute align"
            ),
            .init(
                section: .app,
                id: "canvas-snapping",
                title: String(localized: "settings.app.canvasSnapping", defaultValue: "Canvas Snapping"),
                paths: ["canvas.snappingEnabled"],
                synonyms: "canvas.snappingEnabled canvas snap snapping enabled edges drag resize align panes freeform layout"
            ),
            .init(section: .app, id: "dock-badge", title: "Dock Badge", synonyms: "notifications.dockBadge badge dock unread count icon notifications red bubble"),
            .init(section: .app, id: "show-menu-bar", title: "Show in Menu Bar", synonyms: "notifications.showInMenuBar menubar menu bar status item tray extra"),
            .init(section: .app, id: "unread-pane-ring", title: "Unread Pane Ring", synonyms: "notifications.unreadPaneRing blue border unread ring notification pane outline"),
            .init(section: .app, id: "pane-flash", title: "Pane Flash", synonyms: "notifications.paneFlash flash blink highlight pane notification pulse"),
            .init(section: .app, id: "notification-sound", title: "Notification Sound", synonyms: "notifications.sound sound audio alert chime beep custom file wav mp3 caf aiff"),
            .init(section: .app, id: "notification-command", title: "Notification Command", synonyms: "notifications.command shell command hook script env environment variable variables done agent"),
            .init(section: .app, id: "desktop-notifications", title: "Desktop Notifications", synonyms: "desktop notifications permission authorize enable alerts banners send test notification center"),

            // Terminal
            .init(section: .terminal, id: "scrollbar", title: "Show Terminal Scroll Bar", synonyms: "terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui"),
            .init(
                section: .terminal,
                id: "scroll-speed",
                title: String(localized: "settings.terminal.scrollSpeed", defaultValue: "Scroll Speed"),
                detailText: String(localized: "settings.terminal.scrollSpeed.subtitle", defaultValue: "Multiplier applied to terminal scroll wheel and trackpad deltas. Higher scrolls faster."),
                paths: ["terminal.scrollSpeed"],
                synonyms: "terminal.scrollSpeed scroll speed multiplier wheel mouse trackpad sensitivity faster slower"
            ),
            .init(section: .terminal, id: "copy-on-select", title: "Copy on Selection", synonyms: "terminal.copyOnSelect copy on selection select clipboard mouse double click triple click iterm"),
            .init(section: .terminal, id: "agent-auto-resume", title: "Resume Agent Sessions on Reopen", synonyms: "terminal.autoResumeAgentSessions auto resume restore reopen relaunch quit sessions agents claude code codex opencode rovo dev rovodev toggle"),
            .init(section: .terminal, id: "agent-hibernation", title: "Agent Hibernation", synonyms: "terminal.agentHibernation.enabled idle hibernate suspend background agents claude code codex opencode live terminals"),
            .init(section: .terminal, id: "agent-hibernation-idle", title: "Hibernate After Idle Seconds", synonyms: "terminal.agentHibernation.idleSeconds idle seconds timeout delay hibernate suspend"),
            .init(section: .terminal, id: "agent-hibernation-max", title: "Max Live Agent Terminals", synonyms: "terminal.agentHibernation.maxLiveTerminals max live agent terminals limit count hibernate"),
            .init(section: .terminal, id: "renderer-realization", title: "Reclaim Offscreen Terminal Memory", synonyms: "terminal.rendererRealization.enabled renderer reclaim offscreen memory iosurface gpu idle warm release background terminals"),
            .init(section: .terminal, id: "renderer-realization-idle", title: "Reclaim After Idle Seconds", synonyms: "terminal.rendererRealization.idleSeconds renderer reclaim idle seconds timeout delay offscreen memory"),
            .init(section: .terminal, id: "renderer-realization-max", title: "Max Warm Renderers", synonyms: "terminal.rendererRealization.maxWarmRenderers max warm renderers limit count reclaim offscreen gpu"),
            .init(
                section: .terminal,
                id: "memory-guardrail",
                title: String(localized: "settings.terminal.memoryGuardrail", defaultValue: "Runaway Memory Guardrail"),
                detailText: [
                    String(localized: "settings.terminal.memoryGuardrail.subtitleOn", defaultValue: "cmux warns you with a badge and a banner when one pane's process tree uses too much memory, so a single leak can't crash the whole app."),
                    String(localized: "settings.terminal.memoryGuardrail.subtitleOff", defaultValue: "No warning is shown when a pane's process tree grows large. A leaking process can OOM-suspend the entire app."),
                ].joined(separator: " "),
                synonyms: "terminal.runawayMemoryGuardrail.enabled runaway memory guardrail high memory warning badge banner oom leak process tree pane"
            ),
            .init(
                section: .terminal,
                id: "memory-guardrail-threshold",
                title: String(localized: "settings.terminal.memoryGuardrail.threshold", defaultValue: "Memory Warning Threshold (GB)"),
                detailText: String(localized: "settings.terminal.memoryGuardrail.threshold.subtitle", defaultValue: "A pane is flagged once its combined process-tree memory crosses this many gigabytes."),
                synonyms: "terminal.runawayMemoryGuardrail.thresholdGB memory warning threshold gb gigabytes limit process tree pane"
            ),
            .init(section: .terminal, id: "resume-commands", title: "Resume Commands", synonyms: "terminal.resumeCommands surface resume command approvals prefixes auto restore prompt manual tmux hibernation"),

            // TextBox
            .init(section: .textBox, id: "show-textbox-new-terminals", title: "Show TextBox on New Terminals", synonyms: "terminal.showTextBoxOnNewTerminals show textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "focus-textbox-new-terminals", title: "Focus TextBox on New Terminals", synonyms: "terminal.focusTextBoxOnNewTerminals focus textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "textbox-max-lines", title: "TextBox Max Lines", synonyms: "terminal.textBoxMaxLines textbox text box rich input prompt max height lines grow scroll beta"),

            // Sidebar appearance + sidebar workspace row details
            .init(section: .sidebarAppearance, id: "match-terminal", title: "Match Terminal Background", synonyms: "sidebarAppearance.matchTerminalBackground transparent background material terminal background sync"),
            .init(section: .sidebarAppearance, id: "hide-sidebar-details", title: "Hide All Sidebar Details", synonyms: "sidebar.hideAllDetails compact sidebar hide details only title minimal left rail"),
            .init(section: .sidebarAppearance, id: "wrap-workspace-titles", title: "Wrap Workspace Titles in Sidebar", synonyms: "sidebar.wrapWorkspaceTitles workspace title wrap multiline pr pull request"),
            .init(section: .sidebarAppearance, id: "show-workspace-description", title: "Show Workspace Description in Sidebar", synonyms: "sidebar.showWorkspaceDescription workspace description notes markdown sidebar"),
            .init(section: .sidebarAppearance, id: "sidebar-branch-layout", title: "Sidebar Branch Layout", synonyms: "sidebar.branchLayout sidebar.branchVerticalLayout git branch layout vertical inline cwd directory"),
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
            .init(
                section: .sidebarAppearance,
                id: "show-agent-activity",
                title: String(localized: "settings.app.showAgentActivity", defaultValue: "Show Loading Spinner"),
                detailText: String(localized: "settings.app.showAgentActivity.subtitle", defaultValue: "Show a loading spinner on workspaces with running coding agents or active loaders. Stays visible even when sidebar details are hidden."),
                paths: ["sidebar.showAgentActivity"],
                synonyms: "sidebar.showAgentActivity loading spinner active coding agent agents running activity"
            ),
            .init(
                section: .sidebarAppearance,
                id: "loading-spinner-position",
                title: String(localized: "settings.app.loadingSpinnerPosition", defaultValue: "Loading Spinner Position"),
                detailText: String(localized: "settings.app.loadingSpinnerPosition.subtitle", defaultValue: "Show the spinner on the left (sharing the unread badge slot) or the right of the workspace row."),
                paths: ["sidebar.loadingSpinnerPosition"],
                synonyms: "sidebar.loadingSpinnerPosition loading spinner position left right leading trailing side"
            ),
            .init(
                section: .sidebarAppearance,
                id: "notification-badge-position",
                title: String(localized: "settings.app.notificationBadgePosition", defaultValue: "Notification Badge Position"),
                detailText: String(localized: "settings.app.notificationBadgePosition.subtitle", defaultValue: "Show the unread notification badge on the left or the right of the workspace row."),
                paths: ["sidebar.notificationBadgePosition"],
                synonyms: "sidebar.notificationBadgePosition notification unread badge position left right leading trailing side"
            ),
            .init(section: .sidebarAppearance, id: "show-metadata", title: "Show Custom Metadata in Sidebar", synonyms: "sidebar.showCustomMetadata metadata meta report_meta status custom block"),
            .init(section: .sidebarAppearance, id: "right-max-width", title: "Dock Max Width", synonyms: "sidebar.rightMaxWidth dock right sidebar max width terminal reservation cap logs lazygit"),

            // Mobile
            .init(section: .mobile, id: "pairDevice", title: "Pair a Device", synonyms: "pair pairing add device qr qr code scan iphone ipad ios mobile tailscale connect onboarding sign in"),
            .init(section: .mobile, id: "iOSPairingHost", title: "iOS Pairing", synonyms: "ios iphone ipad mobile pairing local network permission sync"),
            .init(section: .mobile, id: "iOSPairingPort", title: String(localized: "settings.mobile.port", defaultValue: "Pairing Port"), synonyms: "mobile.iOSPairingHost.port ios iphone mobile pairing port tcp listener firewall conflict"),
            .init(section: .mobile, id: "iOSPairingDisplayName", title: String(localized: "settings.mobile.displayName", defaultValue: "Display Name"), synonyms: "mobile.iOSPairingHost.displayName ios iphone mobile pairing display name mac hostname device label"),

            // Custom Sidebars
            .init(section: .customSidebars, id: "enabled", title: String(localized: "settings.customSidebars.enabled", defaultValue: "Show Custom Sidebars"), synonyms: "custom sidebars enable show vibe swift json interpreted picker beta"),
            .init(section: .customSidebars, id: "renderer", title: String(localized: "settings.customSidebars.renderer", defaultValue: "Renderer"), synonyms: "customSidebars.renderer renderer in-process in app remote worker isolated process hover focus typing input"),

            // Beta
            .init(section: .betaFeatures, id: "feed", title: "Feed", synonyms: "feed right sidebar agent decisions permissions questions approval beta unstable"),
            .init(section: .betaFeatures, id: "dock", title: "Dock", synonyms: "dock right sidebar terminal controls tui beta unstable"),
            .init(section: .betaFeatures, id: "customSidebars", title: "Custom Sidebars", synonyms: "custom sidebars swift json interpreted vibe beta unstable"),
            .init(section: .betaFeatures, id: "remoteTmux", title: "Remote tmux", synonyms: "remote tmux ssh control mode -CC mirror session window pane sidebar workspace beta unstable"),

            // Automation
            .init(section: .automation, id: "socket-mode", title: "Socket Control Mode", synonyms: "automation.socketControlMode api socket unix domain control server auth allow password disabled"),
            .init(
                section: .automation,
                id: "workspace-auto-naming",
                title: String(localized: "settings.automation.workspaceAutoNaming", defaultValue: "Workspace Auto-Naming"),
                detailText: [
                    String(localized: "settings.automation.workspaceAutoNaming.subtitleOn", defaultValue: "Workspaces and tabs are named from agent conversations."),
                    String(localized: "settings.automation.workspaceAutoNaming.subtitleOff", defaultValue: "Workspace and tab names are never generated."),
                    String(localized: "settings.automation.workspaceAutoNaming.note", defaultValue: "When enabled, cmux summarizes supported agent sessions into short workspace and tab names using each agent's own binary, refreshed as the topic shifts. Manual renames always win and stop auto-naming for that workspace or tab. Uses your agent account for the short summarization calls."),
                    String(localized: "settings.automation.autoNamingAgent", defaultValue: "Naming Agent"),
                    String(localized: "settings.automation.autoNamingAgent.auto", defaultValue: "Automatic"),
                ].joined(separator: " "),
                paths: ["automation.workspaceAutoNaming"],
                synonyms: String(
                    localized: "settings.search.alias.setting.automation.workspace-auto-naming",
                    defaultValue: "automation.workspaceAutoNaming automation.autoNamingAgent ai auto naming auto-name auto name workspace tab workspaces tabs title titles rename workspace rename tab renaming generated name summarize summary summarizer conversation agent picker naming agent"
                ),
                anchorPath: "automation.workspaceAutoNaming"
            ),
            .init(section: .automation, id: "port-base", title: "Port Base", synonyms: "automation.portBase cmux_port start first base env environment variable"),
            .init(section: .automation, id: "port-range", title: "Port Range Size", synonyms: "automation.portRange cmux_port_end range size count env ports"),

            // Browser
            .init(section: .browser, id: "enable-browser", title: "Enable cmux Browser", synonyms: "browser.disabled enable disable webview embedded browser tabs links"),
            .init(section: .browser, id: "search-engine", title: "Default Search Engine", synonyms: "browser.defaultSearchEngine omnibar address bar google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider engine name url template"),
            .init(section: .browser, id: "search-suggestions", title: "Show Search Suggestions", synonyms: "browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
            .init(section: .browser, id: "theme", title: "Browser Theme", synonyms: "browser.theme web page theme color scheme light dark system"),
            .init(section: .browser, id: "hidden-webview-discard", title: "Browser Memory Saver", synonyms: "browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"),
            .init(section: .browser, id: "hidden-webview-discard-delay", title: "Memory Saver Delay", synonyms: "browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"),
            .init(
                section: .browser,
                id: "ask-where-to-save-downloads",
                title: String(localized: "settings.browser.askWhereToSaveDownloads", defaultValue: "Ask Where to Save Downloads"),
                detailText: String(localized: "settings.browser.askWhereToSaveDownloads.subtitle", defaultValue: "When off, browser downloads save directly to Downloads without a save panel."),
                synonyms: String(localized: "settings.search.alias.setting.browser.ask-where-to-save-downloads", defaultValue: "browser.askWhereToSaveDownloads downloads save panel folder attachments files pdf gmail")
            ),
            .init(section: .browser, id: "terminal-links", title: "Open Terminal Links in cmux Browser", synonyms: "browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href"),
            .init(section: .browser, id: "intercept-open", title: "Intercept open http(s) in Terminal", synonyms: "browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept"),
            .init(section: .browser, id: "host-whitelist", title: "Hosts to Open in Embedded Browser", synonyms: "browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser"),
            .init(section: .browser, id: "external-patterns", title: "URLs to Always Open Externally", synonyms: "browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser"),
            .init(section: .browser, id: "http-allowlist", title: "HTTP Hosts Allowed in Embedded Browser", synonyms: "browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning"),
            .init(section: .browser, id: "react-grab", title: "React Grab Version", synonyms: "browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component"),
            .init(section: .browser, id: "history", title: "Browsing History", synonyms: "browsing history clear visited pages omnibar suggestions delete"),

            // Browser import
            .init(section: .browserImport, id: "import-data", title: "Import Browser Data", synonyms: "chrome safari firefox brave edge arc bookmarks history cookies profiles migration"),
            .init(section: .browserImport, id: "import-hint", title: "Show import hint on blank browser tabs", synonyms: "browser.showImportHintOnBlankTabs blank tab onboarding hint import prompt dismiss"),

            // Global hotkey
            .init(section: .globalHotkey, id: "enable-hotkey", title: "Enable System-Wide Hotkey", synonyms: "app.systemWideHotkeyEnabled global hotkey enable system wide show hide all windows"),
            .init(section: .globalHotkey, id: "shortcut", title: "Show/Hide All Windows", synonyms: "global hotkey shortcut recorder key command option control"),

            // Keyboard shortcuts
            .init(
                section: .keyboardShortcuts,
                id: "shortcuts",
                title: "Keyboard Shortcuts",
                synonyms: [
                    "shortcuts.bindings hotkeys keybindings key bindings commands keyboard accelerators chords cmux json open diff viewer changes review git unstaged split left split right split up split down new pane new split move surface move tab focus pane resize pane close tab close workspace next previous select workspace",
                    Self.keyboardShortcutActionSynonyms,
                ].joined(separator: " ")
            ),
            .init(section: .keyboardShortcuts, id: "modifier-hold-hints", title: String(localized: "settings.shortcuts.showModifierHoldHints", defaultValue: "Show Shortcut Hints While Holding Modifier Keys"), synonyms: "shortcuts.showModifierHoldHints shortcut hints hotkey hints command cmd modifier hold chips badges"),
            .init(section: .keyboardShortcuts, id: "shortcut-chords", title: "Shortcut Chords", synonyms: "tmux prefix ctrl-b control-b multi key sequence chord cmux json"),
            .init(section: .keyboardShortcuts, id: "reset-defaults", title: "Reset Default Shortcuts", synonyms: "reset restore default defaults built in builtin shortcuts hotkeys keybindings commands"),

            // Workspace colors
            .init(section: .workspaceColors, id: "indicator", title: "Workspace Color Indicator", synonyms: "workspaceColors.indicatorStyle tab indicator active workspace style color stripe dot"),
            .init(section: .workspaceColors, id: "selection", title: "Selection Highlight", synonyms: "workspaceColors.selectionColor selected workspace color highlight background active tab"),
            .init(section: .workspaceColors, id: "badge", title: "Notification Badge", synonyms: "workspaceColors.notificationBadgeColor unread notification badge color dot count"),
            .init(section: .workspaceColors, id: "palette", title: "Reset Palette", synonyms: "reset palette named colors restore built-in custom remove default"),

            // cmux.json
            .init(section: .settingsJSON, id: "open-file", title: "User config file", synonyms: "open config file json jsonc config editor ~/.config cmux preferences"),
            .init(section: .settingsJSON, id: "documentation", title: "Documentation", synonyms: "docs documentation schema reference cmux json keys configuration"),

            // Reset
            .init(section: .reset, id: "reset-all", title: "Reset All Settings", synonyms: "factory reset restore defaults clear preferences"),
        ]
    }

    private static var keyboardShortcutActionSynonyms: String {
        ShortcutAction.allCases
            .filter { $0 != .showHideAllWindows }
            .map(\.displayName)
            .joined(separator: " ")
    }
}
