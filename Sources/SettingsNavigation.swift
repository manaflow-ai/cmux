import SwiftUI

enum SettingsNavigationTarget: String, CaseIterable, Identifiable {
    case account
    case app
    case terminal
    case textBox
    case sleepyMode
    case mobile
    case sidebarAppearance
    case customSidebars
    case betaFeatures
    case automation
    case browser
    case browserImport
    case globalHotkey
    case appshots
    case keyboardShortcuts
    case workspaceColors
    case settingsJSON
    case reset

    var id: Self { self }

    var title: String {
        switch self {
        case .account:
            return String(localized: "settings.section.account", defaultValue: "Account")
        case .app:
            return String(localized: "settings.section.app", defaultValue: "App")
        case .terminal:
            return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox:
            return String(localized: "settings.section.textBox", defaultValue: "TextBox (Beta)")
        case .sleepyMode:
            return String(localized: "settings.section.sleepyMode", defaultValue: "Sleepy Mode")
        case .mobile:
            return String(localized: "settings.section.mobile", defaultValue: "Mobile")
        case .workspaceColors:
            return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .sidebarAppearance:
            return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .customSidebars:
            return String(localized: "settings.section.customSidebars", defaultValue: "Custom Sidebars")
        case .betaFeatures:
            return String(localized: "settings.section.betaFeatures", defaultValue: "Beta Features")
        case .automation:
            return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .browser:
            return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport:
            return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey:
            return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .appshots:
            return String(localized: "settings.section.appshots", defaultValue: "Appshots")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .settingsJSON:
            return String(localized: "settings.section.settingsJSON", defaultValue: "cmux.json")
        case .reset:
            return String(localized: "settings.section.reset", defaultValue: "Reset")
        }
    }

    var symbolName: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .app:
            return "gearshape"
        case .terminal:
            return "terminal"
        case .textBox:
            return "textformat"
        case .sleepyMode:
            return "moon.zzz"
        case .mobile:
            return "iphone"
        case .workspaceColors:
            return "paintpalette"
        case .sidebarAppearance:
            return "sidebar.left"
        case .customSidebars:
            return "sidebar.squares.left"
        case .betaFeatures:
            return "exclamationmark.triangle"
        case .automation:
            return "wand.and.sparkles"
        case .browser:
            return "globe"
        case .browserImport:
            return "square.and.arrow.down"
        case .globalHotkey:
            return "keyboard.badge.ellipsis"
        case .appshots:
            return "camera.viewfinder"
        case .keyboardShortcuts:
            return "keyboard"
        case .settingsJSON:
            return "doc.text"
        case .reset:
            return "arrow.counterclockwise"
        }
    }

    var searchText: String {
        switch self {
        case .account:
            return "\(title) sign in team sync"
        case .app:
            return "\(title) appearance language workspace notifications menu bar telemetry default terminal"
        case .terminal:
            return "\(title) scrollbar auto resume restore reopen relaunch quit sessions agents claude codex opencode rovodev hibernation idle suspend commands approvals prefixes toggle"
        case .textBox:
            return "\(title) textbox text box rich input prompt beta new terminal workspace split tab focus height"
        case .sleepyMode:
            return "\(title) sleepy mode screensaver caffeinate keep awake lock touch id battery wifi clock mascot theme glow pixel"
        case .mobile:
            return "\(title) ios iphone ipad mobile pairing local network sync"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .customSidebars:
            return "\(title) custom sidebars vibe swift json interpreted renderer in-process remote worker isolated"
        case .betaFeatures:
            return "\(title) beta experimental unstable feed dock right sidebar"
        case .automation:
            return "\(title) socket integrations hooks ports claude cursor gemini kiro naming auto naming workspace tabs"
        case .browser:
            return "\(title) search engine links history theme"
        case .browserImport:
            return "\(title) browser import data bookmarks history cookies"
        case .globalHotkey:
            return "\(title) system wide shortcut"
        case .appshots:
            return "\(title) appshot screenshot capture frontmost window accessibility screen recording agent context hotkey permissions"
        case .keyboardShortcuts:
            return "\(title) keybindings commands chords"
        case .settingsJSON:
            return "\(title) config file preferences editor documentation schema jsonc reload"
        case .reset:
            return "\(title) defaults"
        }
    }
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("cmux.settings.navigate")
    private static let targetKey = "target"
    private static let anchorKey = "anchor"
    private static let highlightKey = "highlight"

    static func post(_ target: SettingsNavigationTarget, anchorID: String? = nil, highlight: Bool = false) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                targetKey: target.rawValue,
                anchorKey: anchorID ?? SettingsSearchIndex.sectionID(for: target),
                highlightKey: highlight
            ]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        destination(from: notification)?.target
    }

    static func destination(from notification: Notification) -> SettingsNavigationDestination? {
        guard
            let rawValue = notification.userInfo?[targetKey] as? String,
            let target = SettingsNavigationTarget(rawValue: rawValue)
        else {
            return nil
        }
        let anchorID = notification.userInfo?[anchorKey] as? String
        let shouldHighlight = notification.userInfo?[highlightKey] as? Bool ?? false
        return SettingsNavigationDestination(
            target: target,
            anchorID: anchorID ?? SettingsSearchIndex.sectionID(for: target),
            shouldHighlight: shouldHighlight
        )
    }
}

struct SettingsNavigationDestination {
    let target: SettingsNavigationTarget
    let anchorID: String
    let shouldHighlight: Bool
}

struct SettingsSearchHighlightState: Equatable {
    let anchorID: String?
    let token: Int
    let startedAt: Date?
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

extension EnvironmentValues {
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsSearchAnchors(_ anchorIDs: [String]) -> some View {
        let filteredAnchorIDs = anchorIDs.filter { !$0.isEmpty }
        if let primaryAnchorID = filteredAnchorIDs.first {
            self
                .id(primaryAnchorID)
                .modifier(SettingsSearchHighlightModifier(anchorIDs: filteredAnchorIDs))
        } else {
            self
        }
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    @Environment(\.settingsSearchHighlightState) private var highlightState
    let anchorIDs: [String]

    private func matches(_ state: SettingsSearchHighlightState) -> Bool {
        guard let anchorID = state.anchorID else { return false }
        return anchorIDs.contains(anchorID)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if matches(highlightState) {
                    TimelineView(.animation) { context in
                        let opacity = highlightOpacity(at: context.date, for: highlightState)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(opacity * 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(opacity), lineWidth: 2.5)
                            )
                            .shadow(color: Color.accentColor.opacity(opacity * 0.24), radius: 8, x: 0, y: 0)
                    }
                }
            }
    }

    private func highlightOpacity(at date: Date, for state: SettingsSearchHighlightState) -> Double {
        guard matches(state), let startedAt = state.startedAt else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        if elapsed < 0.14 {
            return max(0, min(1, elapsed / 0.14))
        }
        if elapsed < 5 {
            return 1
        }
        if elapsed < 5.9 {
            return max(0, 1 - ((elapsed - 5) / 0.9))
        }
        return 0
    }
}

enum SettingsSearchEntryKind {
    case section
    case setting
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let kind: SettingsSearchEntryKind
    let target: SettingsNavigationTarget
    let title: String
    let subtitle: String?
    let symbolName: String
    let normalizedSearchText: String
    let normalizedSearchWords: [String]
    let normalizedSearchWordSet: Set<String>

    init(
        id: String,
        kind: SettingsSearchEntryKind,
        target: SettingsNavigationTarget,
        title: String,
        subtitle: String?,
        symbolName: String,
        searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        let normalizedSearchText = SettingsSearchIndex.normalized("\(title) \(subtitle ?? "") \(searchText)")
        self.normalizedSearchText = normalizedSearchText
        self.normalizedSearchWords = SettingsSearchIndex.normalizedTokens(for: normalizedSearchText)
        self.normalizedSearchWordSet = Set(normalizedSearchWords)
    }
}

enum SettingsSearchIndex {
    static let defaultSelectionID = sectionID(for: .account)

    private static let sectionEntries: [SettingsSearchEntry] = SettingsNavigationTarget.allCases.map { target in
        SettingsSearchEntry(
            id: sectionID(for: target),
            kind: .section,
            target: target,
            title: target.title,
            subtitle: nil,
            symbolName: target.symbolName,
            searchText: "\(target.rawValue) \(target.searchText) \(SettingsSearchAliasIndex.sectionAliases(for: target))"
        )
    }

    private static let settingEntries: [SettingsSearchEntry] = [
        setting(.account, "account", String(localized: "settings.section.account", defaultValue: "Account"), "sign in login team sync user profile"),
        setting(.app, "language", String(localized: "settings.app.language", defaultValue: "Language"), "locale translation japanese english restart"),
        setting(.app, "appearance", String(localized: "settings.app.appearance", defaultValue: "Appearance"), "theme light dark system"),
        setting(.app, "app-icon", String(localized: "settings.app.appIcon", defaultValue: "App Icon"), "dock icon alternate"),
        setting(.app, "new-workspace-placement", String(localized: "settings.app.newWorkspacePlacement", defaultValue: "New Workspace Placement"), "workspace order position"),
        setting(.app, "workspace-group-new-workspace-placement", String(localized: "settings.app.workspaceGroupNewWorkspacePlacement", defaultValue: "Group New Workspace Placement"), "workspace group command n plus insert position after current top end"),
        setting(.app, "fork-conversation-default", String(localized: "settings.app.forkConversationDefaultDestination", defaultValue: "Fork Conversation Default"), "fork conversation default right left top bottom split tab workspace"),
        setting(.app, "workspace-inherit-working-directory", String(localized: "settings.app.workspaceInheritWorkingDirectory", defaultValue: "Inherit Workspace Working Directory"), "workspace cwd directory current ghostty working-directory"),
        setting(.app, "minimal-mode", String(localized: "settings.app.minimalMode", defaultValue: "Minimal Mode"), "presentation compact chrome"),
        setting(.app, "keep-workspace-open", String(localized: "settings.app.closeWorkspaceOnLastSurfaceShortcut", defaultValue: "Keep Workspace Open When Closing Last Surface"), "close last surface shortcut"),
        setting(.app, "focus-pane-first-click", String(localized: "settings.app.paneFirstClickFocus", defaultValue: "Focus Pane on First Click"), "mouse click focus"),
        setting(.app, "file-drops", String(localized: "settings.app.fileDrop.defaultBehavior", defaultValue: "File Drops"), "drag drop files finder path text terminal editor split preview shift"),
        setting(.app, "preferred-editor", String(localized: "settings.app.preferredEditor", defaultValue: "Open Files With"), "editor code zed subl cmd click file"),
        setting(.app, "supported-file-previews", String(localized: "settings.app.openSupportedFilesInCmux", defaultValue: "Open Supported Files in cmux"), "cmd click file preview pdf image audio video quick look editor"),
        setting(.app, "terminal-config", String(localized: "settings.app.configWindow", defaultValue: "Terminal Config"), "ghostty config merged preview macos-option-as-alt option as alt left option right option alt key meta"),
        setting(.app, "markdown-viewer", String(localized: "settings.app.openMarkdownInCmuxViewer", defaultValue: "Open Markdown in cmux Viewer"), "md markdown viewer"),
        setting(.app, "markdown-font-size", String(localized: "settings.app.markdownFontSize", defaultValue: "Markdown Viewer Font Size"), "md markdown viewer font size points zoom scale text bigger smaller"),
        setting(.app, "markdown-font-family", String(localized: "settings.app.markdownFontFamily", defaultValue: "Markdown Viewer Font"), "markdown.fontFamily md markdown viewer font font-family family typeface system stack custom"),
        setting(.app, "markdown-max-width", String(localized: "settings.app.markdownMaxWidth", defaultValue: "Markdown Viewer Max Width"), "markdown.maxWidth md markdown viewer width column reading line length pixels px"),
        setting(.app, "file-editor-word-wrap", String(localized: "settings.app.fileEditorWordWrap", defaultValue: "File Editor Word Wrap"), "fileEditor.wordWrap file editor word wrap soft wrap reflow lines text horizontal scroll preview"),
        setting(.app, "imessage-mode", String(localized: "settings.app.iMessageMode", defaultValue: "iMessage Mode"), "message messages imessage chat prompt prompts submitted message send agent workspace reorder move top"),
        setting(.app, "reorder-notification", String(localized: "settings.app.reorderOnNotification", defaultValue: "Reorder on Notification"), "workspace notification order"),
        setting(.app, "dock-badge", String(localized: "settings.app.dockBadge", defaultValue: "Dock Badge"), "unread count app icon"),
        setting(.app, "menu-bar-only", String(localized: "settings.app.menuBarOnly", defaultValue: "Menu Bar Only"), "dock icon cmd tab"),
        setting(.app, "show-menu-bar", String(localized: "settings.app.showInMenuBar", defaultValue: "Show in Menu Bar"), "menu extra status item"),
        setting(.app, "unread-pane-ring", String(localized: "settings.notifications.paneRing.title", defaultValue: "Unread Pane Ring"), "notification blue ring pane"),
        setting(.app, "pane-flash", String(localized: "settings.notifications.paneFlash.title", defaultValue: "Pane Flash"), "notification flash highlight"),
        setting(.app, "desktop-notifications", String(localized: "settings.notifications.desktop", defaultValue: "Desktop Notifications"), "permission alerts test notification"),
        setting(.app, "notification-sound", String(localized: "settings.notifications.sound.title", defaultValue: "Notification Sound"), "custom sound alert audio"),
        setting(.app, "notification-command", String(localized: "settings.notifications.command", defaultValue: "Notification Command"), "shell command environment variables"),
        setting(.app, "telemetry", String(localized: "settings.app.telemetry", defaultValue: "Send anonymous telemetry"), "analytics crash usage"),
        setting(.app, "default-terminal", String(localized: "settings.app.defaultTerminal", defaultValue: "Default Terminal"), "ssh links command tool unix executable launch services handler registration system default"),
        setting(.app, "warn-before-quit", String(localized: "settings.app.warnBeforeQuit", defaultValue: "Warn Before Quit"), "cmd q confirmation confirmQuit"),
        setting(.app, "warn-before-closing-tab", String(localized: "settings.app.warnBeforeClosingTab", defaultValue: "Warn Before Closing Tab"), "cmd w close tab confirmation"),
        setting(
            .app,
            "warn-before-closing-tab-x-button",
            String(localized: "settings.app.warnBeforeClosingTabXButton", defaultValue: "Warn Before Tab Close Button"),
            "x button close tab confirmation"
        ),
        setting(
            .app,
            "hide-tab-close-button",
            String(localized: "settings.app.hideTabCloseButton", defaultValue: "Hide Tab Close Button"),
            "hide x button close tab"
        ),
        setting(.app, "rename-selects-name", String(localized: "settings.app.renameSelectsName", defaultValue: "Rename Selects Existing Name"), "command palette rename text selection"),
        setting(.app, "palette-search-all", String(localized: "settings.app.commandPaletteSearchAllSurfaces", defaultValue: "Command Palette Searches All Surfaces"), "cmd p search terminal browser markdown"),
        setting(.app, "canvas-pane-gap", String(localized: "settings.app.canvasPaneGap", defaultValue: "Canvas Pane Gap"), "canvas.paneGap canvas pane gap spacing freeform layout panes snapping tidy distribute align"),
        setting(.app, "canvas-snapping", String(localized: "settings.app.canvasSnapping", defaultValue: "Canvas Snapping"), "canvas.snappingEnabled canvas snap snapping enabled edges drag resize align panes freeform layout"),
        setting(.terminal, "scrollbar", String(localized: "settings.terminal.scrollBar", defaultValue: "Show Terminal Scroll Bar"), "terminal shell scrollback"),
        setting(.terminal, "copy-on-select", String(localized: "settings.terminal.copyOnSelect", defaultValue: "Copy on Selection"), "terminal.copyOnSelect clipboard selection mouse double click triple click"),
        setting(.terminal, "tab-bar-font-size", String(localized: "settings.terminal.tabBarFontSize", defaultValue: "Tab Bar Font Size"), "font size text scale terminal browser pane tab title surface-tab-bar-font-size"),
        setting(.terminal, "agent-auto-resume", String(localized: "settings.terminal.agentAutoResume", defaultValue: "Resume Agent Sessions on Reopen"), "terminal.autoResumeAgentSessions auto resume restore reopen relaunch quit sessions agents claude code codex opencode rovo dev rovodev toggle"),
        setting(.terminal, "agent-hibernation", String(localized: "settings.terminal.agentHibernation", defaultValue: "Agent Hibernation"), "terminal.agentHibernation idle hibernate suspend background agents claude code codex opencode live terminals"),
        setting(.terminal, "renderer-realization", String(localized: "settings.terminal.rendererRealization", defaultValue: "Reclaim Offscreen Terminal Memory"), "terminal.rendererRealization renderer reclaim offscreen memory iosurface gpu idle warm release background terminals"),
        setting(.terminal, "resume-commands", String(localized: "settings.terminal.resumeCommands", defaultValue: "Resume Commands"), "surface resume command approvals prefixes auto restore prompt manual tmux hibernation"),
        setting(.textBox, "show-textbox-new-terminals", String(localized: "settings.textBox.showOnNewTerminals", defaultValue: "Show TextBox on New Terminals"), "terminal.showTextBoxOnNewTerminals textbox text box rich input prompt default new workspace split tab beta"),
        setting(.textBox, "focus-textbox-new-terminals", String(localized: "settings.textBox.focusOnNewTerminals", defaultValue: "Focus TextBox on New Terminals"), "terminal.focusTextBoxOnNewTerminals textbox text box rich input prompt default new workspace split tab beta"),
        setting(.textBox, "textbox-max-lines", String(localized: "settings.textBox.maxLines", defaultValue: "TextBox Max Lines"), "terminal.textBoxMaxLines terminal textbox text box rich input prompt max height lines grow scroll beta"),
        setting(.sidebarAppearance, "match-terminal", String(localized: "settings.sidebarAppearance.matchTerminalBackground", defaultValue: "Match Terminal Background"), "sidebar material transparency"),
        setting(.sidebarAppearance, "font-size", String(localized: "settings.sidebarAppearance.fontSize", defaultValue: "Sidebar Font Size"), "font size text scale workspace title badge metadata shortcut hint sidebar-font-size"),
        setting(.sidebarAppearance, "hide-sidebar-details", String(localized: "settings.app.hideAllSidebarDetails", defaultValue: "Hide All Sidebar Details"), "workspace sidebar compact"),
        setting(.sidebarAppearance, "wrap-workspace-titles", String(localized: "settings.app.wrapWorkspaceTitles", defaultValue: "Wrap Workspace Titles in Sidebar"), "workspace title wrap multiline pr pull request"),
        setting(.sidebarAppearance, "show-workspace-description", String(localized: "settings.app.showWorkspaceDescription", defaultValue: "Show Workspace Description in Sidebar"), "workspace description notes markdown"),
        setting(.sidebarAppearance, "sidebar-branch-layout", String(localized: "settings.app.sidebarBranchLayout", defaultValue: "Sidebar Branch Layout"), "branch directory vertical inline"),
        setting(.sidebarAppearance, "stack-branch-directory", String(localized: "settings.app.stackBranchDirectory", defaultValue: "Stack Branch and Directory"), "branch directory cwd path stack two rows separate lines"),
        setting(.sidebarAppearance, "path-last-segment-only", String(localized: "settings.app.pathLastSegmentOnly", defaultValue: "Truncate Path From Start"), "cwd path directory truncate last segment basename viewport"),
        setting(.sidebarAppearance, "show-notification-message", String(localized: "settings.app.showNotificationMessage", defaultValue: "Show Notification Message in Sidebar"), "workspace latest notification"),
        setting(.sidebarAppearance, "show-branch-directory", String(localized: "settings.app.showBranchDirectory", defaultValue: "Show Branch + Directory in Sidebar"), "git cwd path"),
        setting(.sidebarAppearance, "show-pull-requests", String(localized: "settings.app.showPullRequests", defaultValue: "Show Pull Requests in Sidebar"), "review pr mr link"),
        setting(.sidebarAppearance, "watch-git-status", String(localized: "settings.app.watchGitStatus", defaultValue: "Watch Git Status in Sidebar"), "git status branch watcher index lock"),
        setting(.sidebarAppearance, "make-pr-clickable", String(localized: "settings.app.makeSidebarPullRequestClickable", defaultValue: "Make Sidebar PR Clickable"), "pull requests pull request pr mr review clickable links select workspace row"),
        setting(.sidebarAppearance, "open-pr-links", String(localized: "settings.app.openSidebarPRLinks", defaultValue: "Open Sidebar PR Links in cmux Browser"), "pull request link browser"),
        setting(.sidebarAppearance, "open-port-links", String(localized: "settings.app.openSidebarPortLinks", defaultValue: "Open Sidebar Port Links in cmux Browser"), "port link browser"),
        setting(.sidebarAppearance, "show-ssh", String(localized: "settings.app.showSSH", defaultValue: "Show SSH in Sidebar"), "remote target"),
        setting(.sidebarAppearance, "show-ports", String(localized: "settings.app.showPorts", defaultValue: "Show Listening Ports in Sidebar"), "localhost port"),
        setting(.sidebarAppearance, "show-log", String(localized: "settings.app.showLog", defaultValue: "Show Latest Log in Sidebar"), "status message"),
        setting(.sidebarAppearance, "show-progress", String(localized: "settings.app.showProgress", defaultValue: "Show Progress in Sidebar"), "progress bar"),
        setting(.sidebarAppearance, "show-metadata", String(localized: "settings.app.showMetadata", defaultValue: "Show Custom Metadata in Sidebar"), "report meta status block"),
        setting(.sidebarAppearance, "right-max-width", String(localized: "settings.sidebar.rightMaxWidth", defaultValue: "Dock Max Width"), "dock right sidebar max width terminal reservation cap logs lazygit"),
        setting(.customSidebars, "enabled", String(localized: "settings.customSidebars.enabled", defaultValue: "Show Custom Sidebars"), "custom sidebars enable show vibe swift json interpreted picker"),
        setting(.customSidebars, "renderer", String(localized: "settings.customSidebars.renderer", defaultValue: "Renderer"), "renderer in-process in app remote worker isolated process hover focus typing input"),
        setting(.betaFeatures, "feed", String(localized: "settings.betaFeatures.feed", defaultValue: "Feed"), "feed right sidebar agent decisions permissions questions"),
        setting(.betaFeatures, "dock", String(localized: "settings.betaFeatures.dock", defaultValue: "Dock"), "dock right sidebar terminal controls tui"),
        setting(.automation, "socket-mode", String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"), "unix socket api access password auth"),
        setting(.automation, "socket-password", String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"), "socket auth credential"),
        setting(.automation, "claude-code", String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"), "agent hooks notifications"),
        setting(.automation, "claude-path", String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"), "custom claude executable"),
        setting(
            .automation,
            "workspace-auto-naming",
            String(localized: "settings.automation.workspaceAutoNaming", defaultValue: "Workspace Auto-Naming"),
            [
                "automation.workspaceAutoNaming automation.autoNamingAgent workspace auto naming auto name ai naming names rename workspace rename tab title titles generated name agent summarizer summarize conversation",
                String(localized: "settings.automation.workspaceAutoNaming.subtitleOn", defaultValue: "Workspaces and tabs are named from agent conversations."),
                String(localized: "settings.automation.workspaceAutoNaming.subtitleOff", defaultValue: "Workspace and tab names are never generated."),
                String(localized: "settings.automation.workspaceAutoNaming.note", defaultValue: "When enabled, cmux summarizes supported agent sessions into short workspace and tab names using each agent's own binary, refreshed as the topic shifts. Manual renames always win and stop auto-naming for that workspace or tab. Uses your agent account for the short summarization calls."),
                String(localized: "settings.automation.autoNamingAgent", defaultValue: "Naming Agent"),
                String(localized: "settings.automation.autoNamingAgent.auto", defaultValue: "Automatic")
            ].joined(separator: " ")
        ),
        setting(.automation, "ripgrep-path", String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"), "custom ripgrep rg executable find search nix"),
        setting(.automation, "subagent-notifications", String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"), "nested child agent codex claude hooks notifications"),
        setting(.automation, "cursor", String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"), "agent hooks notifications"),
        setting(.automation, "gemini", String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"), "agent hooks notifications"),
        setting(.automation, "kiro", String(localized: "settings.automation.kiro", defaultValue: "Kiro CLI Integration"), "agent hooks notifications"),
        setting(.automation, "kiro-notification-level", String(localized: "settings.automation.kiro.notificationLevel", defaultValue: "Kiro Notification Level"), "agent hooks notifications verbosity tool events"),
        setting(.automation, "port-base", String(localized: "settings.automation.portBase", defaultValue: "Port Base"), "CMUX_PORT start"),
        setting(.automation, "port-range", String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"), "CMUX_PORT_END workspace ports"),
        setting(.browser, "search-engine", String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"), "address bar query google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider"),
        setting(.browser, "enable-browser", String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"), "webview tabs links"),
        setting(.browser, "search-suggestions", String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions"), "browser address bar suggestions"),
        setting(.browser, "theme", String(localized: "settings.browser.theme", defaultValue: "Browser Theme"), "web appearance light dark system"),
        setting(.browser, "hidden-webview-discard", String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Discard Hidden Browser WebViews"), "memory hidden tabs webview discard unload"),
        setting(.browser, "hidden-webview-discard-delay", String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Hidden WebView Discard Delay"), "memory hidden tabs delay seconds discard"),
        setting(.browser, "ask-where-to-save-downloads", String(localized: "settings.browser.askWhereToSaveDownloads", defaultValue: "Ask Where to Save Downloads"), "downloads save panel download folder attachments files pdf gmail"),
        setting(.browser, "terminal-links", String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"), "click links browser"),
        setting(.browser, "intercept-open", String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"), "open command urls"),
        setting(.browser, "host-whitelist", String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"), "hosts wildcard terminal links"),
        setting(.browser, "external-patterns", String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"), "regex url rules default browser"),
        setting(.browser, "http-allowlist", String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"), "localhost non https warning"),
        setting(.browserImport, "import-data", String(localized: "settings.browser.import", defaultValue: "Import Browser Data"), "bookmarks history cookies profiles"),
        setting(.browserImport, "import-hint", String(localized: "settings.browser.import.hint.show", defaultValue: "Show import hint on blank browser tabs"), "blank tab browser import"),
        setting(.browser, "react-grab", String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"), "npm react grab toolbar"),
        setting(.browser, "history", String(localized: "settings.browser.history", defaultValue: "Browsing History"), "clear visited suggestions"),
        setting(.globalHotkey, "enable-hotkey", String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"), "global shortcut show hide windows"),
        setting(.globalHotkey, "shortcut", String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"), "keyboard recorder command option control"),
        setting(.keyboardShortcuts, "shortcut-chords", String(localized: "settings.shortcuts.chords", defaultValue: "Shortcut Chords"), "tmux multi step keybindings"),
        setting(.keyboardShortcuts, "reset-defaults", String(localized: "settings.shortcuts.resetDefaults", defaultValue: "Reset Default Shortcuts"), "restore built in builtin defaults keybindings hotkeys chords commands"),
        setting(.keyboardShortcuts, "shortcuts", String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"), "keybindings commands"),
        setting(.workspaceColors, "indicator", String(localized: "settings.workspaceColors.indicator", defaultValue: "Workspace Color Indicator"), "tab color indicator"),
        setting(.workspaceColors, "selection", String(localized: "settings.workspaceColors.selectionColor", defaultValue: "Selection Highlight"), "selected workspace background"),
        setting(.workspaceColors, "badge", String(localized: "settings.workspaceColors.notificationBadgeColor", defaultValue: "Notification Badge"), "unread notification color"),
        setting(.workspaceColors, "palette", String(localized: "settings.workspaceColors.resetPalette", defaultValue: "Reset Palette"), "named colors palette"),
        setting(.settingsJSON, "open-file", String(localized: "settings.settingsJSON.openFile", defaultValue: "Open cmux.json"), "config json file editor dotfiles"),
        setting(.settingsJSON, "documentation", String(localized: "settings.settingsJSON.documentation", defaultValue: "Documentation"), "cmux json schema reference docs"),
        setting(.reset, "reset-all", String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings"), "restore defaults")
    ] + terminalScrollSpeedSettingEntries

    private static let allEntries = sectionEntries + settingEntries

    private static let entriesByID: [String: SettingsSearchEntry] = Dictionary(
        uniqueKeysWithValues: allEntries.map { ($0.id, $0) }
    )

    private static let settingsPathAnchorIDs: [String: String] = [
        "rightSidebar.beta.feed.enabled": settingID(for: .betaFeatures, idSuffix: "feed"),
        "rightSidebar.beta.dock.enabled": settingID(for: .betaFeatures, idSuffix: "dock"),
        "app.language": settingID(for: .app, idSuffix: "language"),
        "app.appearance": settingID(for: .app, idSuffix: "appearance"),
        "app.appIcon": settingID(for: .app, idSuffix: "app-icon"),
        "app.newWorkspacePlacement": settingID(for: .app, idSuffix: "new-workspace-placement"),
        "workspaceGroups.newWorkspacePlacement": settingID(for: .app, idSuffix: "workspace-group-new-workspace-placement"),
        "app.forkConversationDefaultDestination": settingID(for: .app, idSuffix: "fork-conversation-default"),
        "app.workspaceInheritWorkingDirectory": settingID(for: .app, idSuffix: "workspace-inherit-working-directory"),
        "app.minimalMode": settingID(for: .app, idSuffix: "minimal-mode"),
        "app.keepWorkspaceOpenWhenClosingLastSurface": settingID(for: .app, idSuffix: "keep-workspace-open"),
        "app.focusPaneOnFirstClick": settingID(for: .app, idSuffix: "focus-pane-first-click"),
        "fileDrop.defaultBehavior": settingID(for: .app, idSuffix: "file-drops"),
        "app.fileDropDefaultBehavior": settingID(for: .app, idSuffix: "file-drops"),
        "app.preferredEditor": settingID(for: .app, idSuffix: "preferred-editor"),
        "app.openSupportedFilesInCmux": settingID(for: .app, idSuffix: "supported-file-previews"),
        "app.openMarkdownInCmuxViewer": settingID(for: .app, idSuffix: "markdown-viewer"),
        "markdown.fontSize": settingID(for: .app, idSuffix: "markdown-font-size"),
        "markdown.fontFamily": settingID(for: .app, idSuffix: "markdown-font-family"),
        "markdown.maxWidth": settingID(for: .app, idSuffix: "markdown-max-width"),
        "fileEditor.wordWrap": settingID(for: .app, idSuffix: "file-editor-word-wrap"),
        "app.iMessageMode": settingID(for: .app, idSuffix: "imessage-mode"),
        "app.reorderOnNotification": settingID(for: .app, idSuffix: "reorder-notification"),
        "notifications.dockBadge": settingID(for: .app, idSuffix: "dock-badge"),
        "app.menuBarOnly": settingID(for: .app, idSuffix: "menu-bar-only"),
        "notifications.showInMenuBar": settingID(for: .app, idSuffix: "show-menu-bar"),
        "notifications.unreadPaneRing": settingID(for: .app, idSuffix: "unread-pane-ring"),
        "notifications.paneFlash": settingID(for: .app, idSuffix: "pane-flash"),
        "notifications.sound": settingID(for: .app, idSuffix: "notification-sound"),
        "notifications.customSoundFilePath": settingID(for: .app, idSuffix: "notification-sound"),
        "notifications.command": settingID(for: .app, idSuffix: "notification-command"),
        "app.sendAnonymousTelemetry": settingID(for: .app, idSuffix: "telemetry"),
        "app.defaultTerminal": settingID(for: .app, idSuffix: "default-terminal"),
        "app.confirmQuit": settingID(for: .app, idSuffix: "warn-before-quit"),
        "app.warnBeforeQuit": settingID(for: .app, idSuffix: "warn-before-quit"),
        "app.warnBeforeClosingTab": settingID(for: .app, idSuffix: "warn-before-closing-tab"),
        "app.warnBeforeClosingTabXButton": settingID(for: .app, idSuffix: "warn-before-closing-tab-x-button"),
        "app.hideTabCloseButton": settingID(for: .app, idSuffix: "hide-tab-close-button"),
        "app.renameSelectsExistingName": settingID(for: .app, idSuffix: "rename-selects-name"),
        "app.commandPaletteSearchesAllSurfaces": settingID(for: .app, idSuffix: "palette-search-all"),
        "canvas.paneGap": settingID(for: .app, idSuffix: "canvas-pane-gap"),
        "canvas.snappingEnabled": settingID(for: .app, idSuffix: "canvas-snapping"),
        "sidebar.hideAllDetails": settingID(for: .sidebarAppearance, idSuffix: "hide-sidebar-details"),
        "sidebar.wrapWorkspaceTitles": settingID(for: .sidebarAppearance, idSuffix: "wrap-workspace-titles"),
        "sidebar.showWorkspaceDescription": settingID(for: .sidebarAppearance, idSuffix: "show-workspace-description"),
        "sidebar.branchLayout": settingID(for: .sidebarAppearance, idSuffix: "sidebar-branch-layout"),
        "sidebar.stackBranchDirectory": settingID(for: .sidebarAppearance, idSuffix: "stack-branch-directory"),
        "sidebar.pathLastSegmentOnly": settingID(for: .sidebarAppearance, idSuffix: "path-last-segment-only"),
        "sidebar.showNotificationMessage": settingID(for: .sidebarAppearance, idSuffix: "show-notification-message"),
        "sidebar.showBranchDirectory": settingID(for: .sidebarAppearance, idSuffix: "show-branch-directory"),
        "sidebar.showPullRequests": settingID(for: .sidebarAppearance, idSuffix: "show-pull-requests"),
        "sidebar.watchGitStatus": settingID(for: .sidebarAppearance, idSuffix: "watch-git-status"),
        "sidebar.makePullRequestsClickable": settingID(for: .sidebarAppearance, idSuffix: "make-pr-clickable"),
        "sidebar.openPullRequestLinksInCmuxBrowser": settingID(for: .sidebarAppearance, idSuffix: "open-pr-links"),
        "sidebar.openPortLinksInCmuxBrowser": settingID(for: .sidebarAppearance, idSuffix: "open-port-links"),
        "sidebar.showSSH": settingID(for: .sidebarAppearance, idSuffix: "show-ssh"),
        "sidebar.showPorts": settingID(for: .sidebarAppearance, idSuffix: "show-ports"),
        "sidebar.showLog": settingID(for: .sidebarAppearance, idSuffix: "show-log"),
        "sidebar.showProgress": settingID(for: .sidebarAppearance, idSuffix: "show-progress"),
        "sidebar.showCustomMetadata": settingID(for: .sidebarAppearance, idSuffix: "show-metadata"),
        "sidebar.rightMaxWidth": settingID(for: .sidebarAppearance, idSuffix: "right-max-width"),
        "sidebar-font-size": settingID(for: .sidebarAppearance, idSuffix: "font-size"),
        "surface-tab-bar-font-size": settingID(for: .terminal, idSuffix: "tab-bar-font-size"),
        "terminal.showScrollBar": settingID(for: .terminal, idSuffix: "scrollbar"),
        "terminal.showTextBoxOnNewTerminals": settingID(for: .textBox, idSuffix: "show-textbox-new-terminals"),
        "terminal.focusTextBoxOnNewTerminals": settingID(for: .textBox, idSuffix: "focus-textbox-new-terminals"),
        "terminal.textBoxMaxLines": settingID(for: .textBox, idSuffix: "textbox-max-lines"),
        "terminal.copyOnSelect": settingID(for: .terminal, idSuffix: "copy-on-select"),
        "terminal.autoResumeAgentSessions": settingID(for: .terminal, idSuffix: "agent-auto-resume"),
        "terminal.agentHibernation.enabled": settingID(for: .terminal, idSuffix: "agent-hibernation"),
        "terminal.agentHibernation.idleSeconds": settingID(for: .terminal, idSuffix: "agent-hibernation"),
        "terminal.agentHibernation.maxLiveTerminals": settingID(for: .terminal, idSuffix: "agent-hibernation"),
        "terminal.rendererRealization.enabled": settingID(for: .terminal, idSuffix: "renderer-realization"),
        "terminal.rendererRealization.idleSeconds": settingID(for: .terminal, idSuffix: "renderer-realization"),
        "terminal.rendererRealization.maxWarmRenderers": settingID(for: .terminal, idSuffix: "renderer-realization"),
        "workspaceColors.indicatorStyle": settingID(for: .workspaceColors, idSuffix: "indicator"),
        "workspaceColors.selectionColor": settingID(for: .workspaceColors, idSuffix: "selection"),
        "workspaceColors.notificationBadgeColor": settingID(for: .workspaceColors, idSuffix: "badge"),
        "sidebarAppearance.matchTerminalBackground": settingID(for: .sidebarAppearance, idSuffix: "match-terminal"),
        "customSidebars.renderer": settingID(for: .customSidebars, idSuffix: "renderer"),
        "automation.socketControlMode": settingID(for: .automation, idSuffix: "socket-mode"),
        "automation.socketPassword": settingID(for: .automation, idSuffix: "socket-password"),
        "automation.claudeCodeIntegration": settingID(for: .automation, idSuffix: "claude-code"),
        "automation.claudeBinaryPath": settingID(for: .automation, idSuffix: "claude-path"),
        "automation.workspaceAutoNaming": settingID(for: .automation, idSuffix: "workspace-auto-naming"),
        "automation.ripgrepBinaryPath": settingID(for: .automation, idSuffix: "ripgrep-path"),
        "automation.suppressSubagentNotifications": settingID(for: .automation, idSuffix: "subagent-notifications"),
        "automation.cursorIntegration": settingID(for: .automation, idSuffix: "cursor"),
        "automation.geminiIntegration": settingID(for: .automation, idSuffix: "gemini"),
        "automation.kiroIntegration": settingID(for: .automation, idSuffix: "kiro"),
        "automation.kiroNotificationLevel": settingID(for: .automation, idSuffix: "kiro-notification-level"),
        "automation.portBase": settingID(for: .automation, idSuffix: "port-base"),
        "automation.portRange": settingID(for: .automation, idSuffix: "port-range"),
        "browser.enabled": settingID(for: .browser, idSuffix: "enable-browser"),
        "browser.defaultSearchEngine": settingID(for: .browser, idSuffix: "search-engine"),
        "browser.customSearchEngineName": settingID(for: .browser, idSuffix: "search-engine"),
        "browser.customSearchEngineURLTemplate": settingID(for: .browser, idSuffix: "search-engine"),
        "browser.showSearchSuggestions": settingID(for: .browser, idSuffix: "search-suggestions"),
        "browser.theme": settingID(for: .browser, idSuffix: "theme"),
        "browser.discardHiddenWebViews": settingID(for: .browser, idSuffix: "hidden-webview-discard"),
        "browser.hiddenWebViewDiscardDelaySeconds": settingID(for: .browser, idSuffix: "hidden-webview-discard-delay"),
        "browser.askWhereToSaveDownloads": settingID(for: .browser, idSuffix: "ask-where-to-save-downloads"),
        "browser.openTerminalLinksInCmuxBrowser": settingID(for: .browser, idSuffix: "terminal-links"),
        "browser.interceptTerminalOpenCommandInCmuxBrowser": settingID(for: .browser, idSuffix: "intercept-open"),
        "browser.hostsToOpenInEmbeddedBrowser": settingID(for: .browser, idSuffix: "host-whitelist"),
        "browser.urlsToAlwaysOpenExternally": settingID(for: .browser, idSuffix: "external-patterns"),
        "browser.insecureHttpHostsAllowedInEmbeddedBrowser": settingID(for: .browser, idSuffix: "http-allowlist"),
        "browser.showImportHintOnBlankTabs": settingID(for: .browserImport, idSuffix: "import-hint"),
        "browser.reactGrabVersion": settingID(for: .browser, idSuffix: "react-grab"),
        "shortcuts.bindings": settingID(for: .keyboardShortcuts, idSuffix: "shortcuts")
    ].merging(terminalScrollSpeedSettingsPathAnchorIDs) { current, _ in current }

    static func entries(matching query: String) -> [SettingsSearchEntry] {
        let tokens = normalizedQueryTokens(for: query)
        guard !tokens.isEmpty else { return sectionEntries }
        let normalizedQuery = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return allEntries.enumerated()
            .compactMap { offset, entry -> (entry: SettingsSearchEntry, score: Int, offset: Int)? in
                guard let score = matchScore(entry: entry, query: normalizedQuery, tokens: tokens) else {
                    return nil
                }
                return (entry, score, offset)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.offset < rhs.offset
            }
            .map(\.entry)
    }

    static func entry(withID id: String) -> SettingsSearchEntry? {
        entriesByID[id]
    }

    static func sectionEntry(for target: SettingsNavigationTarget) -> SettingsSearchEntry {
        entriesByID[sectionID(for: target)] ?? sectionEntries[0]
    }

    static func sectionID(for target: SettingsNavigationTarget) -> String { "section:\(target.rawValue)" }
    static func settingID(for target: SettingsNavigationTarget, idSuffix: String) -> String { "setting:\(target.rawValue):\(idSuffix)" }

    static func anchorID(forSettingsPath path: String) -> String? {
        settingsPathAnchorIDs[path]
    }
}
