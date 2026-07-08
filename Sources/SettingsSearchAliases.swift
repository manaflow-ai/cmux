import Foundation

enum SettingsSearchAliasIndex {
    static func sectionAliases(for target: SettingsNavigationTarget) -> String {
        switch target {
        case .account:
            return localized("settings.search.alias.section.account", defaultValue: "auth authentication login logout sign in sign out email user profile team")
        case .app:
            return localized("settings.search.alias.section.app", defaultValue: "general preferences prefs behavior chrome dock menubar menu bar status notifications telemetry")
        case .terminal:
            return localized("settings.search.alias.section.terminal", defaultValue: "shell scrollback scrollbar scroll bar ghostty tty pty")
        case .textBox:
            return localized("settings.search.alias.section.textBox", defaultValue: "textbox text box rich input prompt beta focus composer compose attachments")
        case .sleepyMode:
            return localized("settings.search.alias.section.sleepyMode", defaultValue: "sleepy mode screensaver caffeinate keep awake do not sleep lock touch id battery wifi clock mascot theme glow pixel night")
        case .mobile:
            return localized("settings.search.alias.section.mobile", defaultValue: "ios iphone ipad mobile pairing local network permission sync")
        case .sidebarAppearance:
            return localized("settings.search.alias.section.sidebarAppearance", defaultValue: "sidebar left rail navigation details branches badges material terminal background")
        case .customSidebars:
            return localized("settings.search.alias.section.customSidebars", defaultValue: "custom sidebars vibe code swift json interpreted renderer in-process remote worker isolated")
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
        "app:default-terminal": localized("settings.search.alias.setting.app.default-terminal", defaultValue: "app.defaultTerminal default terminal ssh links command tool unix executable launch services handler"),
        "app:new-workspace-placement": localized("settings.search.alias.setting.app.new-workspace-placement", defaultValue: "app.newWorkspacePlacement new tab insert position order top bottom end"),
        "app:workspace-group-new-workspace-placement": localized("settings.search.alias.setting.app.workspace-group-new-workspace-placement", defaultValue: "workspaceGroups.newWorkspacePlacement group new workspace command n cmd-n plus insert position after current top end"),
        "app:fork-conversation-default": localized("settings.search.alias.setting.app.fork-conversation-default", defaultValue: "app.forkConversationDefaultDestination fork conversation right left top bottom split tab workspace default"),
        "app:workspace-inherit-working-directory": localized("settings.search.alias.setting.app.workspace-inherit-working-directory", defaultValue: "app.workspaceInheritWorkingDirectory workspace cwd directory inherit current focused ghostty working-directory"),
        "app:minimal-mode": localized("settings.search.alias.setting.app.minimal-mode", defaultValue: "app.minimalMode minimal layout simple chrome compact titlebar controls"),
        "app:keep-workspace-open": localized("settings.search.alias.setting.app.keep-workspace-open", defaultValue: "app.keepWorkspaceOpenWhenClosingLastSurface close last pane surface keep tab workspace"),
        "app:focus-pane-first-click": localized("settings.search.alias.setting.app.focus-pane-first-click", defaultValue: "app.focusPaneOnFirstClick click to focus focus follows mouse first click mouse activation"),
        "app:preferred-editor": localized("settings.search.alias.setting.app.preferred-editor", defaultValue: "app.preferredEditor editor open file code vscode visual studio zed sublime subl cursor"),
        "app:supported-file-previews": localized("settings.search.alias.setting.app.supported-file-previews", defaultValue: "app.openSupportedFilesInCmux cmd click file preview pdf image video audio quicklook quick look editor external"),
        "app:terminal-config": localized("settings.search.alias.setting.app.terminal-config", defaultValue: "ghostty config configuration terminal settings preview merged file reload macos-option-as-alt option as alt left option right option alt key meta"),
        "app:markdown-viewer": localized("settings.search.alias.setting.app.markdown-viewer", defaultValue: "app.openMarkdownInCmuxViewer md markdown mdx viewer preview readme"),
        "app:markdown-font-size": localized("settings.search.alias.setting.app.markdown-font-size", defaultValue: "markdown.fontSize md markdown viewer font size points zoom scale text bigger smaller larger default"),
        "app:markdown-font-family": localized("settings.search.alias.setting.app.markdown-font-family", defaultValue: "markdown.fontFamily md markdown viewer font font-family family typeface system stack custom"),
        "app:markdown-max-width": localized("settings.search.alias.setting.app.markdown-max-width", defaultValue: "markdown.maxWidth md markdown viewer max width column reading line length pixels px narrow wide"),
        "app:file-editor-word-wrap": localized("settings.search.alias.setting.app.file-editor-word-wrap", defaultValue: "fileEditor.wordWrap file editor word wrap soft wrap reflow lines text horizontal scroll preview"),
        "app:imessage-mode": localized("settings.search.alias.setting.app.imessage-mode", defaultValue: "app.iMessageMode imessage message messages chat prompt prompts submitted message texting reorder move workspace top agent send"),
        "app:reorder-notification": localized("settings.search.alias.setting.app.reorder-notification", defaultValue: "app.reorderOnNotification notification reorder move workspace top unread sort"),
        "app:dock-badge": localized("settings.search.alias.setting.app.dock-badge", defaultValue: "notifications.dockBadge badge dock unread count icon notifications red bubble"),
        "app:menu-bar-only": localized("settings.search.alias.setting.app.menu-bar-only", defaultValue: "app.menuBarOnly menubar menu bar dockless hide dock app switcher cmd-tab command-tab"),
        "app:show-menu-bar": localized("settings.search.alias.setting.app.show-menu-bar", defaultValue: "notifications.showInMenuBar menubar menu bar status item tray extra"),
        "app:unread-pane-ring": localized("settings.search.alias.setting.app.unread-pane-ring", defaultValue: "notifications.unreadPaneRing blue border unread ring notification pane outline"),
        "app:pane-flash": localized("settings.search.alias.setting.app.pane-flash", defaultValue: "notifications.paneFlash flash blink highlight pane notification pulse"),
        "app:desktop-notifications": localized("settings.search.alias.setting.app.desktop-notifications", defaultValue: "macos desktop notifications system settings permission alerts notify test"),
        "app:notification-sound": localized("settings.search.alias.setting.app.notification-sound", defaultValue: "notifications.sound notifications.customSoundFilePath sound audio alert chime beep custom file wav mp3 caf aiff"),
        "app:notification-command": localized("settings.search.alias.setting.app.notification-command", defaultValue: "notifications.command shell command hook script env environment variable variables done agent"),
        "app:telemetry": localized("settings.search.alias.setting.app.telemetry", defaultValue: "app.sendAnonymousTelemetry analytics crash reports sentry posthog usage anonymous privacy"),
        "app:warn-before-quit": localized("settings.search.alias.setting.app.warn-before-quit", defaultValue: "app.warnBeforeQuit quit confirmation command-q cmd-q exit close app"),
        "app:warn-before-closing-tab": localized("settings.search.alias.setting.app.warn-before-closing-tab", defaultValue: "app.warnBeforeClosingTab close tab confirmation command-w cmd-w terminal surface"),
        "app:warn-before-closing-tab-x-button": localized(
            "settings.search.alias.setting.app.warn-before-closing-tab-x-button",
            defaultValue: "app.warnBeforeClosingTabXButton close tab x button confirmation terminal surface"
        ),
        "app:hide-tab-close-button": localized(
            "settings.search.alias.setting.app.hide-tab-close-button",
            defaultValue: "app.hideTabCloseButton hide close tab x button terminal surface"
        ),
        "app:rename-selects-name": localized("settings.search.alias.setting.app.rename-selects-name", defaultValue: "app.renameSelectsExistingName rename select all existing title command palette workspace name"),
        "app:palette-search-all": localized("settings.search.alias.setting.app.palette-search-all", defaultValue: "app.commandPaletteSearchesAllSurfaces command palette search all surfaces cmd-p terminal browser markdown"),
        "app:canvas-pane-gap": localized("settings.search.alias.setting.app.canvas-pane-gap", defaultValue: "canvas.paneGap canvas pane gap spacing freeform layout panes snapping tidy distribute align"),
        "app:canvas-snapping": localized("settings.search.alias.setting.app.canvas-snapping", defaultValue: "canvas.snappingEnabled canvas snap snapping enabled edges drag resize align panes freeform layout"),
        "terminal:scrollbar": localized("settings.search.alias.setting.terminal.scrollbar", defaultValue: "terminal.showScrollBar scrollback scrollbar scroll bar right edge alternate screen tui"),
        "terminal:copy-on-select": localized("settings.search.alias.setting.terminal.copy-on-select", defaultValue: "terminal.copyOnSelect copy on selection select clipboard mouse double click triple click iterm"),
        "terminal:tab-bar-font-size": localized("settings.search.alias.setting.terminal.tab-bar-font-size", defaultValue: "surface-tab-bar-font-size tab bar font size text scale terminal browser pane tab title"),
        "terminal:resume-commands": localized("settings.search.alias.setting.terminal.resume-commands", defaultValue: "surface resume commands approvals command prefixes auto restore ask manual tmux hibernation sticky process"),
        "textBox:show-textbox-new-terminals": localized("settings.search.alias.setting.textBox.show-textbox-new-terminals", defaultValue: "terminal.showTextBoxOnNewTerminals show textbox text box rich input prompt default new terminal workspace split tab beta"),
        "textBox:focus-textbox-new-terminals": localized("settings.search.alias.setting.textBox.focus-textbox-new-terminals", defaultValue: "terminal.focusTextBoxOnNewTerminals focus textbox text box rich input prompt default new terminal workspace split tab beta"),
        "textBox:default-submit-action": localized("settings.search.alias.setting.textBox.default-submit-action", defaultValue: "terminal.textBoxDefaultSubmitAction submit action shift tab claude codex opencode pi agent route provider icon new session"),
        "textBox:textbox-max-lines": localized("settings.search.alias.setting.textBox.textbox-max-lines", defaultValue: "terminal.textBoxMaxLines textbox text box rich input prompt max height lines grow scroll beta"),
        "sidebarAppearance:match-terminal": localized("settings.search.alias.setting.sidebarAppearance.match-terminal", defaultValue: "sidebarAppearance.matchTerminalBackground transparent background material terminal background sync"),
        "sidebarAppearance:font-size": localized("settings.search.alias.setting.sidebarAppearance.font-size", defaultValue: "sidebar-font-size sidebar font size text scale workspace title badge metadata shortcut hint"),
        "sidebarAppearance:hide-sidebar-details": localized("settings.search.alias.setting.app.hide-sidebar-details", defaultValue: "sidebar.hideAllDetails compact sidebar hide details only title minimal left rail"),
        "sidebarAppearance:wrap-workspace-titles": localized("settings.search.alias.setting.app.wrap-workspace-titles", defaultValue: "sidebar.wrapWorkspaceTitles workspace title wrap multiline pr pull request"),
        "sidebarAppearance:show-workspace-description": localized("settings.search.alias.setting.app.show-workspace-description", defaultValue: "sidebar.showWorkspaceDescription workspace description notes markdown sidebar"),
        "betaFeatures:workspace-todos": localized("settings.search.alias.setting.betaFeatures.workspace-todos", defaultValue: "sidebar.beta.workspaceTodos.enabled workspace todo task status checklist glyph lane done review working needs attention beta"),
        "betaFeatures:workspace-todos-checklist-style": localized("settings.search.alias.setting.betaFeatures.workspace-todos-checklist-style", defaultValue: "sidebar.beta.workspaceTodos.checklistStyle workspace todo checklist popover inline presentation style beta"),
        "sidebarAppearance:sidebar-branch-layout": localized("settings.search.alias.setting.app.sidebar-branch-layout", defaultValue: "sidebar.branchLayout git branch layout vertical inline cwd directory"),
        "sidebarAppearance:stack-branch-directory": localized("settings.search.alias.setting.app.stack-branch-directory", defaultValue: "sidebar.stackBranchDirectory git branch directory cwd path stack stacked separate lines two rows"),
        "sidebarAppearance:path-last-segment-only": localized("settings.search.alias.setting.app.path-last-segment-only", defaultValue: "sidebar.pathLastSegmentOnly cwd path directory last segment basename short truncate folder repo"),
        "sidebarAppearance:show-notification-message": localized("settings.search.alias.setting.app.show-notification-message", defaultValue: "sidebar.showNotificationMessage latest message unread notification text sidebar"),
        "sidebarAppearance:show-branch-directory": localized("settings.search.alias.setting.app.show-branch-directory", defaultValue: "sidebar.showBranchDirectory git branch cwd path directory folder repo sidebar"),
        "sidebarAppearance:show-pull-requests": localized("settings.search.alias.setting.app.show-pull-requests", defaultValue: "sidebar.showPullRequests pr mr review github gitlab bitbucket pull request merge request"),
        "sidebarAppearance:watch-git-status": localized("settings.search.alias.setting.app.watch-git-status", defaultValue: "sidebar.watchGitStatus git status branch watcher index lock"),
        "sidebarAppearance:make-pr-clickable": localized("settings.search.alias.setting.sidebarAppearance.make-pr-clickable", defaultValue: "sidebar.makePullRequestsClickable clickable pull requests pr mr reviews links select workspace row"),
        "sidebarAppearance:open-pr-links": localized("settings.search.alias.setting.app.open-pr-links", defaultValue: "sidebar.openPullRequestLinksInCmuxBrowser pr links github browser default external embedded"),
        "sidebarAppearance:open-port-links": localized("settings.search.alias.setting.app.open-port-links", defaultValue: "sidebar.openPortLinksInCmuxBrowser ports localhost links browser default external embedded"),
        "sidebarAppearance:show-ssh": localized("settings.search.alias.setting.app.show-ssh", defaultValue: "sidebar.showSSH remote host target ssh server"),
        "sidebarAppearance:show-ports": localized("settings.search.alias.setting.app.show-ports", defaultValue: "sidebar.showPorts localhost port listener dev server url"),
        "sidebarAppearance:show-log": localized("settings.search.alias.setting.app.show-log", defaultValue: "sidebar.showLog log status latest message imperative"),
        "sidebarAppearance:show-progress": localized("settings.search.alias.setting.app.show-progress", defaultValue: "sidebar.showProgress progress bar percent status set_progress"),
        "sidebarAppearance:show-agent-activity": localized("settings.search.alias.setting.app.show-agent-activity", defaultValue: "sidebar.showAgentActivity loading spinner active coding agent agents running activity"),
        "sidebarAppearance:loading-spinner-position": localized("settings.search.alias.setting.app.loading-spinner-position", defaultValue: "sidebar.loadingSpinnerPosition loading spinner position left right leading trailing side workspace"),
        "sidebarAppearance:notification-badge-position": localized("settings.search.alias.setting.app.notification-badge-position", defaultValue: "sidebar.notificationBadgePosition notification unread badge position left right leading trailing side workspace"),
        "sidebarAppearance:show-metadata": localized("settings.search.alias.setting.app.show-metadata", defaultValue: "sidebar.showCustomMetadata metadata meta report_meta status custom block"),
        "sidebarAppearance:right-max-width": localized("settings.search.alias.setting.sidebarAppearance.right-max-width", defaultValue: "sidebar.rightMaxWidth dock right sidebar max width terminal reservation cap logs lazygit"),
        "betaFeatures:feed": localized("settings.search.alias.setting.betaFeatures.feed", defaultValue: "feed right sidebar agent decisions permissions questions approval beta unstable"),
        "betaFeatures:dock": localized("settings.search.alias.setting.betaFeatures.dock", defaultValue: "dock right sidebar terminal controls tui beta unstable"),
        "mobile:iOSPairingHost": localized("settings.search.alias.setting.mobile.iOSPairingHost", defaultValue: "ios iphone ipad mobile pairing local network permission sync"),
        "mobile:iOSPairingPort": localized("settings.search.alias.setting.mobile.iOSPairingPort", defaultValue: "mobile ios iphone pairing port tcp listener firewall conflict bind"),
        "mobile:iOSPairingDisplayName": localized("settings.search.alias.setting.mobile.iOSPairingDisplayName", defaultValue: "mobile ios iphone pairing display name mac hostname device label"),
        "automation:socket-mode": localized("settings.search.alias.setting.automation.socket-mode", defaultValue: "automation.socketControlMode api socket unix domain control server auth allow password disabled"),
        "automation:socket-password": localized("settings.search.alias.setting.automation.socket-password", defaultValue: "automation.socketPassword auth token credential secret password access key"),
        "automation:claude-code": localized("settings.search.alias.setting.automation.claude-code", defaultValue: "automation.claudeCodeIntegration claude code hooks agent integration status notifications"),
        "automation:claude-path": localized("settings.search.alias.setting.automation.claude-path", defaultValue: "automation.claudeBinaryPath claude binary executable path cli command custom"),
        "automation:workspace-auto-naming": localized("settings.search.alias.setting.automation.workspace-auto-naming", defaultValue: "automation.workspaceAutoNaming automation.autoNamingAgent ai auto naming auto-name auto name workspace tab workspaces tabs title titles rename workspace rename tab renaming generated name summarize summary summarizer conversation agent picker naming agent"),
        "automation:ripgrep-path": localized("settings.search.alias.setting.automation.ripgrep-path", defaultValue: "automation.ripgrepBinaryPath ripgrep rg binary executable path search find nix custom"),
        "automation:subagent-notifications": localized("settings.search.alias.setting.automation.subagent-notifications", defaultValue: "automation.suppressSubagentNotifications subagent nested child agent codex claude hooks notifications"),
        "automation:cursor": localized("settings.search.alias.setting.automation.cursor", defaultValue: "automation.cursorIntegration cursor ide agent hooks notifications"),
        "automation:gemini": localized("settings.search.alias.setting.automation.gemini", defaultValue: "automation.geminiIntegration gemini cli google agent hooks notifications"),
        "automation:kiro": localized("settings.search.alias.setting.automation.kiro", defaultValue: "automation.kiroIntegration kiro cli amazon q agent hooks notifications"),
        "automation:kiro-notification-level": localized("settings.search.alias.setting.automation.kiro-notification-level", defaultValue: "automation.kiroNotificationLevel kiro cli notification verbosity minimal standard verbose tool events"),
        "automation:port-base": localized("settings.search.alias.setting.automation.port-base", defaultValue: "automation.portBase cmux_port start first base env environment variable"),
        "automation:port-range": localized("settings.search.alias.setting.automation.port-range", defaultValue: "automation.portRange cmux_port_end range size count env ports"),
        "browser:enable-browser": localized("settings.search.alias.setting.browser.enable-browser", defaultValue: "browser.enabled enable disable webview embedded browser tabs links"),
        "browser:search-engine": localized("settings.search.alias.setting.browser.search-engine", defaultValue: "browser.defaultSearchEngine browser.customSearchEngineName browser.customSearchEngineURLTemplate omnibar address bar google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider"),
        "browser:search-suggestions": localized("settings.search.alias.setting.browser.search-suggestions", defaultValue: "browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
        "browser:theme": localized("settings.search.alias.setting.browser.theme", defaultValue: "browser.theme web page theme color scheme light dark system"),
        "browser:hidden-webview-discard": localized("settings.search.alias.setting.browser.hidden-webview-discard", defaultValue: "browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"),
        "browser:hidden-webview-discard-delay": localized("settings.search.alias.setting.browser.hidden-webview-discard-delay", defaultValue: "browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"),
        "browser:ask-where-to-save-downloads": localized("settings.search.alias.setting.browser.ask-where-to-save-downloads", defaultValue: "browser.askWhereToSaveDownloads downloads save panel folder attachments files pdf gmail"),
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
        "keyboardShortcuts:reset-defaults": localized("settings.search.alias.setting.keyboardShortcuts.reset-defaults", defaultValue: "reset restore default defaults built in builtin shortcuts hotkeys keybindings commands"),
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
        KeyboardShortcutSettings.settingsVisibleActions.map(\.label).joined(separator: " ")
    }

    private static func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue)
    }
}

extension SettingsSearchIndex {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func setting(
        _ target: SettingsNavigationTarget,
        _ idSuffix: String,
        _ title: String,
        _ searchText: String
    ) -> SettingsSearchEntry {
        SettingsSearchEntry(
            id: settingID(for: target, idSuffix: idSuffix),
            kind: .setting,
            target: target,
            title: title,
            subtitle: target.title,
            symbolName: target.symbolName,
            searchText: "\(target.rawValue) \(idSuffix) \(target.searchText) \(searchText) \(SettingsSearchAliasIndex.aliases(target: target, idSuffix: idSuffix))"
        )
    }

    static func normalizedTokens(for query: String) -> [String] {
        normalized(query)
            .split { character in
                character.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                }
            }
            .map(String.init)
    }

    static func normalizedQueryTokens(for query: String) -> [String] {
        normalizedTokens(for: query).filter { !isSearchStopWord($0) }
    }

    private static func isSearchStopWord(_ token: String) -> Bool {
        switch token {
        case "setting", "settings", "preference", "preferences":
            return true
        default:
            return false
        }
    }

    static func matchScore(entry: SettingsSearchEntry, query: String, tokens: [String]) -> Int? {
        var score = 0
        for token in tokens {
            guard let tokenScore = matchScore(
                token: token,
                text: entry.normalizedSearchText,
                words: entry.normalizedSearchWords,
                wordSet: entry.normalizedSearchWordSet
            ) else {
                return nil
            }
            score += tokenScore
        }

        let title = normalized(entry.title)
        if title == query { score -= 1_000 }
        if title.hasPrefix(query) { score -= 800 }
        if containsAtWordBoundary(query, in: title) { score -= 700 }
        if entry.normalizedSearchText.hasPrefix(query) { score -= 600 }
        if containsAtWordBoundary(query, in: entry.normalizedSearchText) { score -= 500 }
        if entry.normalizedSearchText.contains(query) { score -= 400 }
        if case .section = entry.kind { score += 25 }
        return score
    }

    private static func matchScore(token: String, text: String, words: [String], wordSet: Set<String>) -> Int? {
        if wordSet.contains(token) { return 0 }
        if words.contains(where: { $0.hasPrefix(token) }) { return 10 }
        if containsAtWordBoundary(token, in: text) { return 20 }
        if text.contains(token) { return 30 }
        if words.contains(where: { isLightTypo(token, comparedTo: $0) }) { return 50 }
        if words.contains(where: { isSubsequence(token, of: $0) }) { return 60 }
        if isSubsequence(token, of: text) { return 80 }
        return nil
    }

    private static func containsAtWordBoundary(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return true
            }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if !previous.isLetter, !previous.isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in haystack where character == needle[index] {
            index = needle.index(after: index)
            if index == needle.endIndex { return true }
        }
        return false
    }

    private static func isLightTypo(_ token: String, comparedTo word: String) -> Bool {
        let tokenCount = token.count
        let wordCount = word.count
        guard tokenCount >= 4, wordCount >= 4 else { return false }
        let allowedDistance = min(tokenCount, wordCount) >= 6 ? 2 : 1
        guard abs(tokenCount - wordCount) <= allowedDistance else { return false }
        return editDistance(token, word, maximum: allowedDistance) <= allowedDistance
    }

    private static func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        if abs(lhs.count - rhs.count) > maximum { return maximum + 1 }
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let cost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
