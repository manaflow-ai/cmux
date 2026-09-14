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
    /// Titles use the host app’s catalog, matching the visible rows.
    /// English titles remain search aliases alongside localized titles
    /// so both languages find the same setting. Tests and hosts that want
    /// a different set of entries pass their own array via
    /// ``SettingsSearchIndex/init(catalog:curatedEntries:)``.
    public static var cmuxDefault: [CuratedSettingEntry] {
        [
            // Account / integrations
            .init(section: .account, id: "account", title: String(localized: "settings.section.account", defaultValue: "Account"), synonyms: "Account auth authentication login logout signin sign-in signout sign-out email user profile stack team"),
            .init(section: .automation, id: "claude-code", title: String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"), synonyms: "Claude Code Integration automation.claudeCodeIntegration claude code hooks agent integration status notifications"),
            .init(section: .automation, id: "claude-path", title: String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"), synonyms: "Claude Binary Path automation.claudeBinaryPath claude binary executable path cli command custom"),
            .init(section: .automation, id: "ripgrep-path", title: String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"), synonyms: "Ripgrep Binary Path automation.ripgrepBinaryPath ripgrep rg binary executable path search find nix custom"),
            .init(section: .automation, id: "subagent-notifications", title: String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"), synonyms: "Suppress Subagent Notifications automation.suppressSubagentNotifications subagent nested child agent codex claude hooks notifications"),
            .init(section: .automation, id: "cursor", title: String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"), synonyms: "Cursor Integration automation.cursorIntegration cursor ide agent hooks notifications"),
            .init(section: .automation, id: "gemini", title: String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"), synonyms: "Gemini CLI Integration automation.geminiIntegration gemini cli google agent hooks notifications"),

            // App
            .init(section: .app, id: "language", title: String(localized: "settings.app.language", defaultValue: "Language"), synonyms: "Language app.language locale l10n localization translation japanese english ja en nihongo restart"),
            .init(section: .app, id: "appearance", title: String(localized: "settings.app.appearance", defaultValue: "Appearance"), synonyms: "Appearance app.appearance theme color scheme light mode dark mode system mode"),
            .init(section: .app, id: "app-icon", title: String(localized: "settings.app.appIcon", defaultValue: "App Icon"), synonyms: "App Icon app.appIcon dock icon application icon app switcher alternate icon"),
            .init(section: .app, id: "new-workspace-placement", title: String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"), synonyms: "New Workspace Placement app.newWorkspacePlacement new tab insert position order top bottom end"),
            .init(section: .app, id: "workspace-layouts", title: String(localized: "settings.app.workspaceLayouts", defaultValue: "Workspace Layouts"), synonyms: "workspace layouts customize layout default new workspace menu save delete cmux.json actions"),
            .init(section: .app, id: "workspace-inherit-working-directory", title: String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"), synonyms: "Inherit Workspace Working Directory app.workspaceInheritWorkingDirectory workspace cwd directory inherit current focused working-directory"),
            .init(section: .app, id: "minimal-mode", title: String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"), synonyms: "Minimal Mode app.minimalMode presentation compact chrome layout simple titlebar controls"),
            .init(section: .app, id: "keep-workspace-open", title: String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"), synonyms: "Keep Workspace Open When Closing Last Surface app.keepWorkspaceOpenWhenClosingLastSurface close last pane surface keep tab workspace"),
            .init(section: .app, id: "focus-pane-first-click", title: String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"), synonyms: "Focus Pane on First Click app.focusPaneOnFirstClick click to focus focus follows mouse first click mouse activation"),
            .init(
                section: .app,
                id: "focus-history-scope",
                title: String(localized: "settings.app.focusHistoryIncludesPanesAndTabs", defaultValue: "Include Panes and Tabs in Focus History"),
                synonyms: "app.focusHistoryIncludesPanesAndTabs focus history back forward panes tabs workspaces only navigation"
            ),
            .init(section: .app, id: "file-drops", title: String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"), synonyms: "File Drops drag drop files finder path text terminal editor split preview shift"),
            .init(section: .app, id: "preferred-editor", title: String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"), synonyms: "Open Files With app.preferredEditor editor open file code vscode visual studio zed sublime subl cursor"),
            .init(section: .app, id: "supported-file-previews", title: String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"), synonyms: "Open Supported Files in cmux app.openSupportedFilesInCmux cmd click file preview pdf image video audio quicklook quick look editor external"),
            .init(section: .app, id: "markdown-viewer", title: String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"), synonyms: "Open Markdown in cmux Viewer app.openMarkdownInCmuxViewer md markdown mdx viewer preview readme"),
            .init(section: .app, id: "file-editor-word-wrap", title: String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap"), synonyms: "fileEditor.wordWrap " + String(localized: "settings.search.fileEditor.wordWrap", defaultValue: "file editor word wrap soft wrap reflow lines text horizontal scroll preview")),
            .init(
                section: .app,
                id: "file-editor-syntax-highlighting",
                title: String(localized: "settings.app.fileEditorSyntaxHighlighting", defaultValue: "File Editor Syntax Highlighting"),
                synonyms: "fileEditor.syntaxHighlighting " + String(localized: "settings.search.fileEditor.syntaxHighlighting", defaultValue: "syntax highlight colors tokens code")
            ),
            .init(
                section: .app,
                id: "file-editor-line-numbers",
                title: String(localized: "settings.app.fileEditorLineNumbers", defaultValue: "File Editor Line Numbers"),
                synonyms: "fileEditor.lineNumbers " + String(localized: "settings.search.fileEditor.lineNumbers", defaultValue: "gutter line numbers")
            ),
            .init(
                section: .app,
                id: "file-editor-indent-guides",
                title: String(localized: "settings.app.fileEditorIndentGuides", defaultValue: "File Editor Indent Guides"),
                synonyms: "fileEditor.indentGuides " + String(localized: "settings.search.fileEditor.indentGuides", defaultValue: "indent guides columns")
            ),
            .init(
                section: .app,
                id: "file-editor-current-line-highlight",
                title: String(localized: "settings.app.fileEditorCurrentLineHighlight", defaultValue: "File Editor Current Line Highlight"),
                synonyms: "fileEditor.currentLineHighlight " + String(localized: "settings.search.fileEditor.currentLineHighlight", defaultValue: "current line caret highlight")
            ),
            .init(
                section: .app,
                id: "file-editor-tab-width",
                title: String(localized: "settings.app.fileEditorTabWidth", defaultValue: "File Editor Tab Width"),
                synonyms: "fileEditor.tabWidth " + String(localized: "settings.search.fileEditor.tabWidth", defaultValue: "tab width indent columns")
            ),
            .init(section: .app, id: "terminal-config", title: String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"), synonyms: "Terminal Config ghostty config merged generated preview terminal configuration window open config macos-option-as-alt option as alt left option right option alt key meta"),
            .init(section: .app, id: "global-font-magnification", title: String(localized: "settings.app.globalFontMagnification", defaultValue: "Global Font Magnification"), synonyms: "app.globalFontMagnification global font magnification scale text zoom terminals tabs chrome bigger smaller accessibility"),
            .init(section: .app, id: "imessage-mode", title: String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode"), synonyms: "iMessage Mode app.iMessageMode imessage message messages chat prompt prompts submitted texting reorder move workspace top agent send"),
            .init(section: .app, id: "reorder-notification", title: String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"), synonyms: "Reorder on Notification app.reorderOnNotification notification reorder move workspace top unread sort"),
            .init(section: .app, id: "menu-bar-only", title: String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"), synonyms: "Menu Bar Only app.menuBarOnly menubar menu bar dockless hide dock app switcher cmd-tab command-tab"),
            .init(section: .app, id: "telemetry", title: String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"), synonyms: "Send anonymous telemetry app.sendAnonymousTelemetry analytics crash reports sentry posthog usage anonymous privacy"),
            .init(section: .app, id: "warn-before-quit", title: String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"), synonyms: "Warn Before Quit app.confirmQuit quit confirmation command-q cmd-q exit close app"),
            .init(section: .app, id: "warn-before-closing-tab", title: String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"), synonyms: "Warn Before Closing Tab app.warnBeforeClosingTab close tab confirmation command-w cmd-w terminal surface"),
            .init(section: .app, id: "warn-before-closing-tab-x-button", title: String(localized: "settings.app.warnBeforeClosingTabXButton", defaultValue: "Warn Before Tab Close Button"), synonyms: "Warn Before Tab Close Button app.warnBeforeClosingTabXButton x button close tab confirmation terminal surface"),
            .init(section: .app, id: "hide-tab-close-button", title: String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button"), synonyms: "Hide Tab Close Button app.hideTabCloseButton hide x button close tab terminal surface"),
            .init(section: .app, id: "rename-selects-name", title: String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"), synonyms: "Rename Selects Existing Name app.renameSelectsExistingName rename select all existing title command palette workspace name"),
            .init(section: .app, id: "palette-search-all", title: String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"), synonyms: "Command Palette Searches All Surfaces app.commandPaletteSearchesAllSurfaces command palette search all surfaces cmd-p terminal browser markdown"),
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
            .init(section: .app, id: "dock-badge", title: String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"), synonyms: "Dock Badge notifications.dockBadge badge dock unread count icon notifications red bubble"),
            .init(section: .app, id: "show-menu-bar", title: String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"), synonyms: "Show in Menu Bar notifications.showInMenuBar menubar menu bar status item tray extra"),
            .init(section: .app, id: "unread-pane-ring", title: String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring"), synonyms: "Unread Pane Ring notifications.unreadPaneRing blue border unread ring notification pane outline"),
            .init(section: .app, id: "pane-flash", title: String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash"), synonyms: "Pane Flash notifications.paneFlash flash blink highlight pane notification pulse"),
            .init(
                section: .app,
                id: "agent-permission-prompt",
                title: String(localized: "settings.notifications.agentPermissionPrompt.title", defaultValue: "Agent Needs Permission"),
                synonyms: "notifications.agentPermissionPrompt agent permission prompt approval blocked claude codex tool notify"
            ),
            .init(
                section: .app,
                id: "agent-turn-complete",
                title: String(localized: "settings.notifications.agentTurnComplete.title", defaultValue: "Agent Finished"),
                synonyms: "notifications.agentTurnComplete agent finished turn complete done completed when idle always never background tasks monitor notify"
            ),
            .init(
                section: .app,
                id: "agent-idle-reminder",
                title: String(localized: "settings.notifications.agentIdleReminder.title", defaultValue: "Agent Waiting for Input"),
                synonyms: "notifications.agentIdleReminder agent waiting input idle reminder nag notify claude"
            ),
            .init(section: .app, id: "notification-sound", title: String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"), synonyms: "Notification Sound notifications.sound sound audio alert chime beep custom file wav mp3 caf aiff"),
            .init(
                section: .app,
                id: "notification-sound-overrides",
                title: String(localized: "settings.notifications.soundOverrides.title", defaultValue: "Per-Agent Notification Sounds"),
                synonyms: String(
                    localized: "settings.search.alias.setting.app.notification-sound-overrides",
                    defaultValue: "notifications.soundOverrides per-agent agent sound turn done needs input permission error stalled custom file"
                )
            ),
            .init(section: .app, id: "notification-command", title: String(localized: "settings.notifications.command", defaultValue: "Notification Command"), synonyms: "Notification Command notifications.command shell command hook script env environment variable variables done agent"),
            .init(section: .app, id: "desktop-notifications", title: String(localized: "settings.notifications.desktop", defaultValue: "Desktop Notifications"), synonyms: "Desktop Notifications desktop notifications permission authorize enable alerts banners send test notification center"),

            // Terminal
            .init(
                section: .terminal,
                id: "adaptive-default-theme",
                title: String(localized: "settings.terminal.adaptiveDefaultTheme", defaultValue: "Adapt Default Theme to Appearance"),
                detailText: [
                    String(
                        localized: "settings.terminal.adaptiveDefaultTheme.subtitleOn",
                        defaultValue: "cmux's managed light and dark palettes follow the app appearance only when your Ghostty config has no settings. Existing Ghostty settings are never overlaid."
                    ),
                    String(
                        localized: "settings.terminal.adaptiveDefaultTheme.subtitleOff",
                        defaultValue: "An untouched Ghostty config uses Ghostty's fixed built-in palette. Existing Ghostty settings, including light/dark theme pairs, are always preserved."
                    ),
                ].joined(separator: " "),
                paths: ["terminal.adaptiveDefaultTheme"],
                synonyms: String(
                    localized: "settings.search.alias.setting.terminal.adaptive-default-theme",
                    defaultValue: "terminal.adaptiveDefaultTheme adaptive default theme appearance light dark palette Ghostty managed colors empty untouched config preserve settings"
                )
            ),
            .init(section: .terminal, id: "scrollbar", title: String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"), synonyms: "Show Terminal Scroll Bar terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui"),
            .init(
                section: .terminal,
                id: "scroll-speed",
                title: String(localized: "settings.terminal.scrollSpeed", defaultValue: "Scroll Speed"),
                detailText: String(localized: "settings.terminal.scrollSpeed.subtitle", defaultValue: "Multiplier applied to terminal scroll wheel and trackpad deltas. Higher scrolls faster."),
                paths: ["terminal.scrollSpeed"],
                synonyms: "terminal.scrollSpeed scroll speed multiplier wheel mouse trackpad sensitivity faster slower"
            ),
            .init(section: .terminal, id: "copy-on-select", title: String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"), synonyms: "Copy on Selection terminal.copyOnSelect copy on selection select clipboard mouse double click triple click iterm"),
            .init(section: .terminal, id: "agent-auto-resume", title: String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"), synonyms: "Resume Agent Sessions on Reopen terminal.autoResumeAgentSessions auto resume restore reopen relaunch quit sessions agents claude code codex opencode rovo dev rovodev toggle"),
            .init(section: .terminal, id: "agent-hibernation", title: String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"), synonyms: "Agent Hibernation terminal.agentHibernation.enabled idle hibernate suspend background agents claude code codex opencode live terminals"),
            .init(section: .terminal, id: "agent-hibernation-idle", title: String(localized: "settings.terminal.agentHibernation.idleSeconds", defaultValue: "Hibernate After Idle Seconds"), synonyms: "Hibernate After Idle Seconds terminal.agentHibernation.idleSeconds idle seconds timeout delay hibernate suspend"),
            .init(section: .terminal, id: "agent-hibernation-max", title: String(localized: "settings.terminal.agentHibernation.maxLiveTerminals", defaultValue: "Max Live Agent Terminals"), synonyms: "Max Live Agent Terminals terminal.agentHibernation.maxLiveTerminals max live agent terminals limit count hibernate"),
            .init(section: .terminal, id: "renderer-realization", title: String(localized: "settings.terminal.rendererRealization", defaultValue: "Reclaim Offscreen Terminal Memory"), synonyms: "Reclaim Offscreen Terminal Memory terminal.rendererRealization.enabled renderer reclaim offscreen memory iosurface gpu idle warm release background terminals"),
            .init(section: .terminal, id: "renderer-realization-idle", title: String(localized: "settings.terminal.rendererRealization.idleSeconds", defaultValue: "Reclaim After Idle Seconds"), synonyms: "Reclaim After Idle Seconds terminal.rendererRealization.idleSeconds renderer reclaim idle seconds timeout delay offscreen memory"),
            .init(section: .terminal, id: "renderer-realization-max", title: String(localized: "settings.terminal.rendererRealization.maxWarmRenderers", defaultValue: "Max Warm Renderers"), synonyms: "Max Warm Renderers terminal.rendererRealization.maxWarmRenderers max warm renderers limit count reclaim offscreen gpu"),
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
            .init(section: .terminal, id: "resume-commands", title: String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"), synonyms: "Resume Commands terminal.resumeCommands surface resume command approvals prefixes auto restore prompt manual tmux hibernation"),
            .init(
                section: .terminal,
                id: "session-content-width",
                title: String(localized: "settings.terminal.sessionContentWidth", defaultValue: "Session Content Width"),
                synonyms: String(localized: "settings.search.alias.setting.terminal.session-content-width", defaultValue: "terminal.sessionContentMaxWidth terminal agent chat max width readable line length points pt narrow wide")
            ),
            .init(
                section: .terminal,
                id: "session-content-alignment",
                title: String(localized: "settings.terminal.sessionContentAlignment", defaultValue: "Session Content Alignment"),
                synonyms: String(localized: "settings.search.alias.setting.terminal.session-content-alignment", defaultValue: "terminal.sessionContentAlignment terminal agent chat left center right alignment position")
            ),

            // TextBox
            .init(section: .textBox, id: "show-textbox-new-terminals", title: String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals"), synonyms: "Show TextBox on New Terminals terminal.showTextBoxOnNewTerminals show textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "focus-textbox-new-terminals", title: String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals"), synonyms: "Focus TextBox on New Terminals terminal.focusTextBoxOnNewTerminals focus textbox text box rich input prompt default new terminal workspace split tab beta"),
            .init(section: .textBox, id: "default-submit-action", title: String(localized: "settings.textBox.defaultSubmitAction", defaultValue: "Default Submit Action"), synonyms: "terminal.textBoxDefaultSubmitAction submit action shift tab claude codex opencode pi agent route provider icon new session"),
            .init(section: .textBox, id: "textbox-max-lines", title: String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines"), synonyms: "TextBox Max Lines terminal.textBoxMaxLines textbox text box rich input prompt max height lines grow scroll beta"),

            // Sidebar appearance + sidebar workspace row details
            .init(section: .sidebarAppearance, id: "match-terminal", title: String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), synonyms: "Match Terminal Background sidebarAppearance.matchTerminalBackground transparent background material terminal background sync"),
            .init(section: .sidebarAppearance, id: "hide-sidebar-details", title: String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"), synonyms: "Hide All Sidebar Details sidebar.hideAllDetails compact sidebar hide details only title minimal left rail"),
            .init(section: .sidebarAppearance, id: "wrap-workspace-titles", title: String(localized: "settings.app.wrapWorkspaceTitles", defaultValue: "Wrap Workspace Titles in Sidebar"), synonyms: "Wrap Workspace Titles in Sidebar sidebar.wrapWorkspaceTitles workspace title wrap multiline pr pull request"),
            .init(section: .sidebarAppearance, id: "show-workspace-description", title: String(localized: "settings.app.showWorkspaceDescription", defaultValue: "Show Workspace Description in Sidebar"), synonyms: "Show Workspace Description in Sidebar sidebar.showWorkspaceDescription workspace description notes markdown sidebar"),
            .init(section: .sidebarAppearance, id: "sidebar-branch-layout", title: String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"), synonyms: "Sidebar Branch Layout sidebar.branchLayout sidebar.branchVerticalLayout git branch layout vertical inline cwd directory"),
            .init(section: .sidebarAppearance, id: "stack-branch-directory", title: String(localized: "settings.app.stackBranchDirectory", defaultValue: "Stack Branch and Directory"), synonyms: "Stack Branch and Directory sidebar.stackBranchDirectory git branch directory cwd path stack stacked separate lines two rows"),
            .init(section: .sidebarAppearance, id: "path-last-segment-only", title: String(localized: "settings.app.pathLastSegmentOnly", defaultValue: "Truncate Path From Start"), synonyms: "Truncate Path From Start sidebar.pathLastSegmentOnly cwd path directory last segment basename short truncate folder repo"),
            .init(section: .sidebarAppearance, id: "show-notification-message", title: String(localized: "settings.app.showNotificationMessage", defaultValue: "Show Notification Message in Sidebar"), synonyms: "Show Notification Message in Sidebar sidebar.showNotificationMessage latest message unread notification text sidebar"),
            .init(section: .sidebarAppearance, id: "notification-message-line-limit", title: String(localized: "settings.app.notificationMessageLineLimit", defaultValue: "Notification Preview Lines"), synonyms: "sidebar.notificationMessageLineLimit notification message preview lines limit sidebar"),
            .init(section: .sidebarAppearance, id: "show-branch-directory", title: String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar"), synonyms: "Show Branch + Directory in Sidebar sidebar.showBranchDirectory git branch cwd path directory folder repo sidebar"),
            .init(section: .sidebarAppearance, id: "show-pull-requests", title: String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"), synonyms: "Show Pull Requests in Sidebar sidebar.showPullRequests pr mr review github gitlab bitbucket pull request merge request"),
            .init(section: .sidebarAppearance, id: "watch-git-status", title: String(localized: "settings.app.watchGitStatus", defaultValue: "Watch Git Status in Sidebar"), synonyms: "Watch Git Status in Sidebar sidebar.watchGitStatus git status branch watcher index lock"),
            .init(section: .sidebarAppearance, id: "make-pr-clickable", title: String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"), synonyms: "Make Sidebar PR Clickable sidebar.makePullRequestsClickable clickable pull requests pr mr reviews links select workspace row"),
            .init(section: .sidebarAppearance, id: "open-pr-links", title: String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"), synonyms: "Open Sidebar PR Links in cmux Browser sidebar.openPullRequestLinksInCmuxBrowser pr links github browser default external embedded"),
            .init(section: .sidebarAppearance, id: "open-port-links", title: String(localized: "settings.app.openSidebarPortLinks", defaultValue: "Open Sidebar Port Links in cmux Browser"), synonyms: "Open Sidebar Port Links in cmux Browser sidebar.openPortLinksInCmuxBrowser ports localhost links browser default external embedded"),
            .init(section: .sidebarAppearance, id: "show-ssh", title: String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar"), synonyms: "Show SSH in Sidebar sidebar.showSSH remote host target ssh server"),
            .init(section: .sidebarAppearance, id: "show-ports", title: String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"), synonyms: "Show Listening Ports in Sidebar sidebar.showPorts localhost port listener dev server url"),
            .init(section: .sidebarAppearance, id: "show-log", title: String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"), synonyms: "Show Latest Log in Sidebar sidebar.showLog log status latest message imperative"),
            .init(section: .sidebarAppearance, id: "show-progress", title: String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"), synonyms: "Show Progress in Sidebar sidebar.showProgress progress bar percent status set_progress"),
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
            .init(section: .sidebarAppearance, id: "show-metadata", title: String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"), synonyms: "Show Custom Metadata in Sidebar sidebar.showCustomMetadata metadata meta report_meta status custom block"),
            .init(section: .sidebarAppearance, id: "right-max-width", title: String(localized: "settings.sidebar.rightMaxWidth", defaultValue: "Dock Max Width"), synonyms: "Dock Max Width sidebar.rightMaxWidth dock right sidebar max width terminal reservation cap logs lazygit"),

            // Mobile
            .init(
                section: .mobile,
                id: "pairDevice",
                title: String(localized: "settings.mobile.pairDevice", defaultValue: "Tailscale Pairing"),
                synonyms: """
                pair pairing add device qr qr code scan iphone ipad ios mobile \
                tailscale connect onboarding sign in
                """
            ),
            .init(
                section: .mobile,
                id: "phone-push-forwarding",
                title: String(
                    localized: "settings.mobile.phonePush.forwarding",
                    defaultValue: "Forward Notifications to iPhone"
                ),
                detailText: [
                    String(
                        localized: "settings.mobile.phonePush.forwarding.subtitleOn",
                        defaultValue: "Sends local agent alerts from this Mac to cmux on your iPhone and iPad."
                    ),
                    String(
                        localized: "settings.mobile.phonePush.forwarding.subtitleOff",
                        defaultValue: "Stops this Mac from sending local agent alerts to mobile devices."
                    ),
                ].joined(separator: " "),
                synonyms: "push notifications iphone ipad mobile forwarding agent alerts forwardNotificationsToPhone"
            ),
            .init(
                section: .mobile,
                id: "phone-push-mode",
                title: String(
                    localized: "settings.mobile.phonePush.mode",
                    defaultValue: "When to Send"
                ),
                detailText: String(
                    localized: "settings.mobile.phonePush.mode.subtitle",
                    defaultValue: "Always sends every local agent alert. Away mode waits until this Mac is locked, asleep, or idle."
                ),
                synonyms: "push notification forwarding always only when away locked asleep idle forwardNotificationsToPhoneMode"
            ),
            .init(
                section: .mobile,
                id: "phone-push-hide-content",
                title: String(
                    localized: "settings.mobile.phonePush.hideContent",
                    defaultValue: "Hide Notification Content"
                ),
                detailText: String(
                    localized: "settings.mobile.phonePush.hideContent.subtitle",
                    defaultValue: "Sends a generic message instead of agent and terminal text."
                ),
                synonyms: "push notification privacy hide content generic message terminal text forwardNotificationsHideContent"
            ),
            .init(section: .mobile, id: "iOSPairingHost", title: String(localized: "settings.mobile.iOSPairingHost", defaultValue: "iOS Pairing"), synonyms: "iOS Pairing ios iphone ipad mobile pairing local network permission sync"),
            .init(section: .mobile, id: "iOSPairingPort", title: String(localized: "settings.mobile.port", defaultValue: "Pairing Port"), synonyms: "mobile.iOSPairingHost.port ios iphone mobile pairing port tcp listener firewall conflict"),
            .init(section: .mobile, id: "iOSPairingDisplayName", title: String(localized: "settings.mobile.displayName", defaultValue: "Display Name"), synonyms: "mobile.iOSPairingHost.displayName ios iphone mobile pairing display name mac hostname device label"),
            .init(
                section: .mobile,
                id: "artifactFolderAccess",
                title: String(localized: "settings.mobile.artifactFolderAccess", defaultValue: "Folder Access"),
                detailText: String(localized: "settings.mobile.artifactFolderAccess.subtitleSubtree", defaultValue: "Lets iOS browse any item inside a folder referenced by chat or visible in a terminal."),
                paths: ["mobile.artifactFolderAccess"],
                synonyms: "ios iphone ipad mobile files folders directory subtree one level authorization security"
            ),

            // Custom Sidebars
            .init(section: .customSidebars, id: "enabled", title: String(localized: "settings.customSidebars.enabled", defaultValue: "Show Custom Sidebars"), synonyms: "custom sidebars enable show vibe swift json interpreted picker beta"),
            .init(section: .customSidebars, id: "renderer", title: String(localized: "settings.customSidebars.renderer", defaultValue: "Renderer"), synonyms: "customSidebars.renderer renderer in-process in app remote worker isolated process hover focus typing input"),

            // Beta
            .init(section: .betaFeatures, id: "feed", title: String(localized: "settings.betaFeatures.feed", defaultValue: "Feed"), synonyms: "Feed feed right sidebar agent decisions permissions questions approval beta unstable"),
            .init(section: .betaFeatures, id: "dock", title: String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"), synonyms: "Dock dock right sidebar terminal controls tui beta unstable"),
            .init(
                section: .betaFeatures,
                id: "cloudMachines",
                title: String(localized: "settings.betaFeatures.cloudMachines", defaultValue: "Cloud Machines"),
                detailText: [
                    String(localized: "settings.betaFeatures.cloudMachines.subtitleOn", defaultValue: "Shows Cloud in the right sidebar plus the Cloud Machines settings, palette commands, and new-workspace entries."),
                    String(localized: "settings.betaFeatures.cloudMachines.subtitleOff", defaultValue: "Hides every Cloud Machines surface unless remote rollout enables it."),
                ].joined(separator: " "),
                paths: ["cloud.beta.machines.enabled"],
                synonyms: "cloud machines vm virtual machine right sidebar persistent computer beta unstable"
            ),
            .init(section: .betaFeatures, id: "customSidebars", title: String(localized: "settings.betaFeatures.customSidebars", defaultValue: "Custom Sidebars"), synonyms: "Custom Sidebars custom sidebars swift json interpreted vibe beta unstable"),
            .init(section: .betaFeatures, id: "remoteTmux", title: String(localized: "settings.betaFeatures.remoteTmux", defaultValue: "Remote tmux"), synonyms: "Remote tmux remote tmux ssh control mode -CC mirror session window pane sidebar workspace beta unstable"),
            .init(
                section: .betaFeatures,
                id: "workspace-todo-controls",
                title: String(localized: "settings.betaFeatures.workspaceTodoControls", defaultValue: "Workspace Todo Controls"),
                detailText: [
                    String(localized: "settings.betaFeatures.workspaceTodoControls.subtitleOn", defaultValue: "Shows Add Checklist Item and workspace status controls."),
                    String(localized: "settings.betaFeatures.workspaceTodoControls.subtitleOff", defaultValue: "Keeps workspace todo summaries read-only unless remote rollout enables the controls."),
                ].joined(separator: " "),
                paths: ["sidebar.beta.workspaceTodos.controls.enabled"],
                synonyms: String(localized: "settings.search.alias.setting.betaFeatures.workspace-todo-controls", defaultValue: "sidebar.beta.workspaceTodos.controls.enabled workspace todo todos task status checklist add item controls beta")
            ),
            .init(
                section: .betaFeatures,
                id: "workspace-todos-checklist-style",
                title: String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle", defaultValue: "Checklist Style"),
                detailText: [
                    String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.subtitlePopover", defaultValue: "Clicking a row's checklist summary opens an anchored popover."),
                    String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.subtitleInline", defaultValue: "Clicking a row's checklist summary expands the items inline under the row."),
                    String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.popover", defaultValue: "Popover"),
                    String(localized: "settings.betaFeatures.workspaceTodosChecklistStyle.inline", defaultValue: "Inline"),
                ].joined(separator: " "),
                paths: ["sidebar.beta.workspaceTodos.checklistStyle"],
                synonyms: String(localized: "settings.search.alias.setting.betaFeatures.workspace-todos-checklist-style", defaultValue: "sidebar.beta.workspaceTodos.checklistStyle workspace todo todos task status checklist popover inline presentation style beta")
            ),

            // Automation
            .init(section: .automation, id: "socket-mode", title: String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"), synonyms: "Socket Control Mode automation.socketControlMode api socket unix domain control server auth allow password disabled"),
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
            .init(section: .automation, id: "port-base", title: String(localized: "settings.automation.portBase", defaultValue: "Port Base"), synonyms: "Port Base automation.portBase cmux_port start first base env environment variable"),
            .init(section: .automation, id: "port-range", title: String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), synonyms: "Port Range Size automation.portRange cmux_port_end range size count env ports"),

            // Computer Use
            .init(
                section: .computerUse,
                id: "enabled",
                title: String(localized: "settings.computerUse.enabled", defaultValue: "Enable Computer Use"),
                paths: ["computerUse.enabled"],
                synonyms: String(localized: "settings.search.alias.setting.computerUse.enabled", defaultValue: "computerUse.enabled enable disable computer use cua mcp agent sessions")
            ),
            .init(
                section: .computerUse,
                id: "permissions",
                title: String(localized: "settings.computerUse.permissions", defaultValue: "Permissions"),
                synonyms: String(localized: "settings.search.alias.setting.computerUse.permissions", defaultValue: "accessibility screen recording capture permissions privacy system settings grant")
            ),
            .init(
                section: .computerUse,
                id: "show-in-menu-bar",
                title: String(localized: "settings.computerUse.showInMenuBar", defaultValue: "Show Computer Use in Menu Bar"),
                paths: ["computerUse.showInMenuBar"],
                synonyms: String(localized: "settings.search.alias.setting.computerUse.showInMenuBar", defaultValue: "computerUse.showInMenuBar menu bar menubar status item cursor agents")
            ),
            // Browser
            .init(section: .browser, id: "enable-browser", title: String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"), synonyms: "Enable cmux Browser browser.disabled enable disable webview embedded browser tabs links"),
            .init(section: .browser, id: "search-engine", title: String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"), synonyms: "Default Search Engine browser.defaultSearchEngine omnibar address bar google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider engine name url template"),
            .init(section: .browser, id: "search-suggestions", title: String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions"), synonyms: "Show Search Suggestions browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
            .init(section: .browser, id: "theme", title: String(localized: "settings.browser.theme", defaultValue: "Browser Theme"), synonyms: "Browser Theme browser.theme web page theme color scheme light dark system"),
            .init(section: .browser, id: "hidden-webview-discard", title: String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"), synonyms: "Browser Memory Saver browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"),
            .init(section: .browser, id: "hidden-webview-discard-delay", title: String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"), synonyms: "Memory Saver Delay browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"),
            .init(
                section: .browser,
                id: "ask-where-to-save-downloads",
                title: String(localized: "settings.browser.askWhereToSaveDownloads", defaultValue: "Ask Where to Save Downloads"),
                detailText: String(localized: "settings.browser.askWhereToSaveDownloads.subtitle", defaultValue: "When off, browser downloads save directly to Downloads without a save panel."),
                synonyms: String(localized: "settings.search.alias.setting.browser.ask-where-to-save-downloads", defaultValue: "browser.askWhereToSaveDownloads downloads save panel folder attachments files pdf gmail")
            ),
            .init(section: .browser, id: "terminal-links", title: String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"), synonyms: "Open Terminal Links in cmux Browser browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href"),
            .init(section: .browser, id: "intercept-open", title: String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"), synonyms: "Intercept open http(s) in Terminal browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept"),
            .init(section: .browser, id: "host-whitelist", title: String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"), synonyms: "Hosts to Open in Embedded Browser browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser"),
            .init(section: .browser, id: "external-patterns", title: String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"), synonyms: "URLs to Always Open Externally browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser"),
            .init(section: .browser, id: "http-allowlist", title: String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"), synonyms: "HTTP Hosts Allowed in Embedded Browser browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning"),
            .init(
                section: .browser,
                id: "url-allowlist",
                title: String(localized: "settings.browser.urlAllowlist", defaultValue: "Embedded Browser URL Allowlist"),
                synonyms: String(localized: "settings.search.alias.setting.browser.url-allowlist", defaultValue: "browser.urlAllowlist URL allowlist localhost wildcard scheme port organization policy")
            ),
            .init(section: .browser, id: "react-grab", title: String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"), synonyms: "React Grab Version browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component"),
            .init(section: .browser, id: "history", title: String(localized: "settings.browser.history", defaultValue: "Browsing History"), synonyms: "Browsing History browsing history clear visited pages omnibar suggestions delete"),

            // Browser import
            .init(section: .browserImport, id: "import-data", title: String(localized: "settings.browser.import", defaultValue: "Import Browser Data"), synonyms: "Import Browser Data chrome safari firefox brave edge arc bookmarks history cookies profiles migration"),
            .init(section: .browserImport, id: "import-hint", title: String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"), synonyms: "Show import hint on blank browser tabs browser.showImportHintOnBlankTabs blank tab onboarding hint import prompt dismiss"),

            // Global hotkey
            .init(section: .globalHotkey, id: "enable-hotkey", title: String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"), synonyms: "Enable System-Wide Hotkey app.systemWideHotkeyEnabled global hotkey enable system wide show hide all windows"),
            .init(section: .globalHotkey, id: "shortcut", title: String(localized: "settings.globalHotkey.shortcut", defaultValue: "Show/Hide All Windows"), synonyms: "Show/Hide All Windows global hotkey shortcut recorder key command option control"),

            // Keyboard shortcuts
            .init(
                section: .keyboardShortcuts,
                id: "shortcuts",
                title: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                synonyms: [
                    "shortcuts.bindings hotkeys keybindings key bindings commands keyboard accelerators chords cmux json open diff viewer changes review git unstaged split left split right split up split down new pane new split move surface move tab focus pane resize pane close tab close workspace next previous select workspace",
                    Self.keyboardShortcutActionSynonyms,
                ].joined(separator: " ")
            ),
            .init(section: .keyboardShortcuts, id: "modifier-hold-hints", title: String(localized: "settings.shortcuts.showModifierHoldHints", defaultValue: "Show Shortcut Hints While Holding Modifier Keys"), synonyms: "Show Shortcut Hints While Holding Modifier Keys shortcuts.showModifierHoldHints shortcut hints hotkey hints command cmd modifier hold chips badges"),
            .init(section: .keyboardShortcuts, id: "shortcut-chords", title: String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"), synonyms: "Shortcut Chords tmux prefix ctrl-b control-b multi key sequence chord cmux json"),
            .init(section: .keyboardShortcuts, id: "reset-defaults", title: String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"), synonyms: "Reset Default Shortcuts reset restore default defaults built in builtin shortcuts hotkeys keybindings commands"),

            // Workspace colors
            .init(section: .workspaceColors, id: "indicator", title: String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"), synonyms: "Workspace Color Indicator workspaceColors.indicatorStyle tab indicator active workspace style color stripe dot"),
            .init(section: .workspaceColors, id: "selection", title: String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"), synonyms: "Selection Highlight workspaceColors.selectionColor selected workspace color highlight background active tab"),
            .init(section: .workspaceColors, id: "badge", title: String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"), synonyms: "Notification Badge workspaceColors.notificationBadgeColor unread notification badge color dot count"),
            .init(
                section: .workspaceColors,
                id: "pane-flash-color",
                title: String(localized: "settings.workspaceColors.paneFlashColor", defaultValue: "Pane Flash"),
                detailText: String(localized: "settings.workspaceColors.paneFlashColor.subtitle", defaultValue: "Color of the attention ring and pane flash when a pane needs input."),
                paths: ["notifications.paneFlashColor"],
                synonyms: "notifications.paneFlashColor attention ring pane flash color unread needs input"
            ),
            .init(section: .workspaceColors, id: "palette", title: String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"), synonyms: "Reset Palette reset palette named colors restore built-in custom remove default"),

            // cmux.json
            .init(section: .settingsJSON, id: "open-file", title: String(localized: "settings.settingsJSON.file", defaultValue: "User config file"), synonyms: "User config file open config file json jsonc config editor ~/.config cmux preferences"),
            .init(section: .settingsJSON, id: "documentation", title: String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation"), synonyms: "Documentation docs documentation schema reference cmux json keys configuration"),

            // Reset
            .init(section: .reset, id: "reset-all", title: String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings"), synonyms: "Reset All Settings factory reset restore defaults clear preferences"),
        ]
    }

    private static var keyboardShortcutActionSynonyms: String {
        ShortcutAction.allCases
            .filter { $0 != .showHideAllWindows }
            .map(\.displayName)
            .joined(separator: " ")
    }
}
