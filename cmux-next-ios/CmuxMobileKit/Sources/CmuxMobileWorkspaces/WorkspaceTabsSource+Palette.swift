#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileModel
import CmuxTabsKit
import Foundation

/// Which list the command palette shows (the Mac's palette scopes, `palette.open`).
public enum PaletteScope: String, Hashable, Identifiable, Sendable {
    /// Every action for the workspace, its tab and its chat, then New Tab from Text, then tabs.
    case actions
    /// Search Tabs…: the tabs of every workspace on the active team's Macs.
    case tabs
    public var id: String { rawValue }
}

/// One palette row.
public struct PaletteCommand: Identifiable {
    public enum Section: Int, Comparable, Sendable {
        case actions
        /// New Tab from Text and Open Link: what the typed text opens.
        case text
        case tabs
        public static func < (lhs: Section, rhs: Section) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var systemImage: String
    public var section: Section
    public var isEnabled = true
    public var isDestructive = false
    /// The row goes somewhere else (a tab of another workspace, a jump, a link): it runs in the
    /// tap, with the sheet closing, as the address bar's rows do. Run after the sheet was gone, a
    /// move to another workspace's page was dropped (rig run of pq_palette.py searchtabs). Rows
    /// that present something (a dialog, a sheet, a page) wait for the sheet to go instead.
    public var navigates = false
    let run: @MainActor () -> Void

    /// Case- and diacritic-insensitive: every word of `query` is in the title or subtitle.
    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [title, subtitle ?? ""].joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// The command palette (the Mac's Command Palette…, `WindowActionCatalog` and `CmuxNextPalette`):
/// the rows are the page menu's and card menu's own items for the tab on screen, the + menu's
/// new-tab options and the workspace-wide jumps, so every phone action is searchable and none is
/// listed twice. Typed text adds New Tab from Text and Open Link after the matching actions; a query also finds tabs in
/// every workspace (Search Tabs).
extension WorkspaceTabsSource {
    /// Opens the palette (the page menu's Command Palette…, Cmd-Shift-P, Cmd-K).
    public func openPalette(_ scope: PaletteScope = .actions) {
        guard palette == nil else { return }
        pendingPaletteRun = nil
        // The rows for the tab on screen, taken once as the palette opens: the sheet never
        // rebuilds them while it is up (a Mac publish mid-search left it empty, rig run).
        paletteActionRows = scope == .actions ? paletteActions() : []
        palette = scope
    }

    /// A row was picked: the sheet closes; a navigation runs now, any other row once the sheet
    /// is gone (`paletteDismissed`).
    public func pick(_ command: PaletteCommand) {
        guard command.isEnabled else { return }
        if command.navigates {
            pendingPaletteRun = nil
            palette = nil
            command.run()
            return
        }
        pendingPaletteRun = command.run
        palette = nil
    }

    /// The sheet is gone (its content disappeared): runs the picked row, if any.
    public func paletteDismissed() {
        let run = pendingPaletteRun
        pendingPaletteRun = nil
        run?()
    }

    static let paletteItemID = "palette.open"
    /// The Mac's titles (`action.commandPalette`, `action.tab.search`).
    public static let paletteTitle = "Command Palette…"
    public static let searchTabsTitle = "Search Tabs…"

    /// The page menu's row that opens the palette.
    var paletteItems: [TabsKitMenuItem] {
        [TabsKitMenuItem(id: Self.paletteItemID, title: Self.paletteTitle, systemImage: "command") { [weak self] in
            self?.openPalette()
        }]
    }

    /// The actions for the tab on screen and the workspace, deduplicated by menu id.
    public func paletteActions() -> [PaletteCommand] {
        var seen = Set<String>()
        var out: [PaletteCommand] = []
        func add(_ item: TabsKitMenuItem, prefix: String = "") {
            guard item.id != Self.paletteItemID, seen.insert(prefix + item.id).inserted else { return }
            out.append(PaletteCommand(id: "menu.\(prefix)\(item.id)", title: item.title, systemImage: item.systemImage,
                                      section: .actions, isEnabled: item.isEnabled, isDestructive: item.isDestructive,
                                      run: item.action))
        }
        if let active = tabs.first(where: { $0.id == activeTabID }) {
            for item in pageMenu(for: active).flatMap({ $0 }) { add(item) }
            for item in cardMenu(for: active).flatMap({ $0 }) { add(item) }
        }
        // The + menu's options (New Agent Chat, New Terminal, New Browser Tab, …).
        for option in newTabOptions where seen.insert("new.\(option.id)").inserted {
            out.append(PaletteCommand(id: "new.\(option.id)", title: option.title, systemImage: option.systemImage,
                                      section: .actions) { [weak self] in
                Task { @MainActor in _ = await self?.createTab(option) }
            })
        }
        out.append(PaletteCommand(id: "tab.search", title: Self.searchTabsTitle, systemImage: "magnifyingglass",
                                  section: .actions) { [weak self] in self?.openPalette(.tabs) })
        if attentionBackend != nil {
            out.append(PaletteCommand(id: "jumpToUnread", title: TabJump.unread.title, systemImage: "bell.badge",
                                      section: .actions, navigates: true) { [weak self] in self?.jump(.unread) })
            out.append(PaletteCommand(id: "jumpToLastPrompt", title: TabJump.lastPrompt.title,
                                      systemImage: "arrow.uturn.backward.circle", section: .actions, navigates: true) { [weak self] in
                self?.jump(.lastPrompt)
            })
        }
        return out
    }

    // MARK: Search Tabs (every workspace)

    /// Tabs in every workspace on the active team's Macs whose title, subtitle, address or
    /// workspace matches `query` (all of them for an empty query). This workspace's first.
    public func paletteTabs(matching query: String, otherWorkspacesOnly: Bool = false, limit: Int = 200) -> [PaletteCommand] {
        let workspaces = store.activeWorkspaces.filter { !store.isPending($0.id) && !(otherWorkspacesOnly && $0.id == workspaceID) }
        let ordered = workspaces.filter { $0.id == workspaceID } + workspaces.filter { $0.id != workspaceID }
        let macs = Dictionary(store.teams.flatMap(\.macs).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var out: [PaletteCommand] = []
        for workspace in ordered {
            for tab in workspace.tabs {
                let title = Self.searchTitle(tab, in: workspace)
                let place = [workspace.title, macs[workspace.macID]].compactMap(\.self).joined(separator: " · ")
                let detail = [tab.kind == .browser ? tab.url?.host() : tab.subtitle, place].compactMap(\.self)
                    .filter { !$0.isEmpty && $0 != title }.joined(separator: " · ")
                let command = PaletteCommand(id: "tab.\(workspace.id).\(tab.id)", title: title, subtitle: detail,
                                             systemImage: Self.symbol(tab), section: .tabs, navigates: true) { [weak self] in
                    self?.go(toTab: tab.id, in: workspace.id)
                }
                guard command.matches(query) || (tab.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false) else { continue }
                out.append(command)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// A chat's own title (its session's), else the tab's.
    static func searchTitle(_ tab: WorkspaceTab, in workspace: Workspace) -> String {
        if tab.kind == .agent, let title = AgentSessionDirectory.shared.existingStore(id: tab.id, macID: workspace.macID)?.displayTitle,
           !title.isEmpty { return title }
        return tab.title
    }

    static func symbol(_ tab: WorkspaceTab) -> String {
        switch tab.kind {
        case .agent: "sparkle"
        case .terminal: "apple.terminal"
        case .browser: "globe"
        case .simulator: "iphone"
        }
    }

    /// Shows `tabID`: here when it is this workspace's, else in its own workspace's page.
    public func go(toTab tabID: String, in workspaceID: String) {
        if workspaceID == self.workspaceID {
            activate(tabID)
            openedTab = tabID
            return
        }
        guard let destination = store.workspace(id: workspaceID) else {
            return show("That workspace is no longer listed.")
        }
        store.noteOpened(tabID: tabID, in: destination.id)
        guard let openWorkspace else { return show("Open \(destination.title) from Workspaces.") }
        openWorkspace(destination)
    }

    // MARK: Jump to Latest Unread, Jump to Last Prompt

    public enum TabJump: Sendable {
        case unread, lastPrompt
        /// The Mac's titles (`action.jumpToUnread`, `action.jumpToLastPrompt`).
        public var title: String { self == .unread ? "Jump to Latest Unread" : "Jump to Last Prompt" }
    }

    var attentionBackend: (any TabAttentionBackend)? { creator?.backend as? any TabAttentionBackend }

    /// Goes to the tab the Mac's action would: the newest unread notification, or the agent
    /// prompted last, on any Mac of the active team; says why when there is none.
    public func jump(_ kind: TabJump) {
        guard let backend = attentionBackend else { return }
        let macs = Array(Set(store.activeWorkspaces.map(\.macID))).sorted()
        let place = kind == .unread ? backend.latestUnreadTab(on: macs) : backend.lastPromptedTab(on: macs)
        guard let place, store.workspace(id: place.workspaceID)?.tabs.contains(where: { $0.id == place.tabID }) == true else {
            return show(kind == .unread ? TabAttentionPlace.noUnread : TabAttentionPlace.noPrompt)
        }
        go(toTab: place.tabID, in: place.workspaceID)
    }

    // MARK: New Tab from Text, Open Link

    /// What the typed text opens: a cmux link, else the Mac's New Tab from Text table (a
    /// terminal for `!`, a browser tab for an address, a chat for a prompt), and an explicit
    /// web search for anything but a command.
    public func paletteText(_ query: String) -> [PaletteCommand] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let url = URL(string: text), CmuxLink(url: url) != nil {
            return [PaletteCommand(id: "link.open", title: "Open Link", subtitle: text, systemImage: "link", section: .text,
                                   navigates: true) {
                CmuxLinkOpener.shared.open(url)
            }]
        }
        guard canEditTabs else { return [] }
        var rows: [PaletteCommand] = []
        switch NewTabText(text) {
        case .none: break
        case .terminal(let command):
            rows.append(PaletteCommand(id: "newTab.terminal", title: "New Terminal", subtitle: command.isEmpty ? nil : command,
                                       systemImage: "apple.terminal", section: .text) { [weak self] in
                self?.submitText(.terminal(command: command))
            })
        case .address(let url):
            rows.append(PaletteCommand(id: "newTab.address", title: "Open in New Tab", subtitle: url.absoluteString,
                                       systemImage: "globe", section: .text) { [weak self] in
                self?.submitText(.address(url))
            })
        case .prompt(let prompt):
            rows.append(PaletteCommand(id: "newTab.chat", title: "Ask in New Agent Chat", subtitle: prompt,
                                       systemImage: "sparkle", section: .text) { [weak self] in
                self?.submitText(.prompt(prompt))
            })
        }
        if case .terminal = NewTabText(text) { return rows }
        if let search = NewTabText.searchURL(text) {
            rows.append(PaletteCommand(id: "newTab.search", title: "Search the Web", subtitle: text,
                                       systemImage: "magnifyingglass", section: .text) { [weak self] in
                self?.submitText(.address(search))
            })
        }
        return rows
    }

    /// The Mac's New Tab from Text title (`action.newTab.submit`).
    public static let newTabFromTextTitle = "New Tab from Text"

    /// Opens what the text means, on the Mac, and goes to it: a browser tab beside the tab on
    /// screen (`new-browser-tab {url, pane}`), a terminal with the command typed, or a new
    /// agent chat that sends the prompt.
    func submitText(_ meaning: NewTabText) {
        if let pending = pendingTabTitle { return show("Still opening \(pending). Try again once it's open.") }
        switch meaning {
        case .none: return
        case .address(let url):
            if let active = activeTabID, workspaceTab(active) != nil {
                Task { @MainActor [weak self] in
                    guard let self, let opened = await self.openAddressInNewTab(url.absoluteString, besides: active) else { return }
                    self.activate(opened)
                    self.openedTab = opened
                }
                return
            }
            open(Self.option(.browser)) { source, tab, _ in source.navigate(tab.id, to: url.absoluteString) }
        case .terminal(let command):
            open(Self.option(.terminal)) { source, tab, workspace in
                if !command.isEmpty { source.terminal.draft(command, for: tab, in: workspace) }
            }
        case .prompt(let prompt):
            open(Self.option(.agentChat)) { source, tab, workspace in
                source.chatStore(tab, workspace).send(prompt: prompt)
            }
        }
    }

    /// Creates `option`'s tab on the Mac (as the + menu does), then hands it to `then`.
    private func open(_ option: TabsKitNewTabOption,
                      then: @escaping @MainActor (WorkspaceTabsSource, WorkspaceTab, Workspace) -> Void) {
        pendingTabTitle = option.title
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = await self.requestTab(option)
            self.pendingTabTitle = nil
            guard let id, let tab = self.workspaceTab(id), let workspace = self.workspace else { return }
            self.openedTab = id
            then(self, tab, workspace)
        }
    }

    // MARK: Mute Chat Notifications (phone-local)

    var sessionNaming: (any ChatSessionNaming)? { creator?.backend as? any ChatSessionNaming }

    /// The chat's Mute Chat Notifications / Unmute Chat Notifications row (the Mac's
    /// `agentChat.toggleNotificationMute`), on this phone only: its pushes arrive quietly.
    func muteItems(_ tab: WorkspaceTab) -> [TabsKitMenuItem] {
        guard tab.kind == .agent, let workspace, let session = sessionNaming?.agentSessionID(of: tab, in: workspace) else { return [] }
        let mutes = ChatMuteList.shared
        let muted = mutes.isMuted(mac: workspace.macID, session: session)
        return [TabsKitMenuItem(id: "agentChat.toggleNotificationMute",
                                title: muted ? "Unmute Chat Notifications" : "Mute Chat Notifications",
                                systemImage: muted ? "bell" : "bell.slash") { [weak self] in
            mutes.setMuted(!muted, mac: workspace.macID, session: session)
            self?.show(muted ? "Notifications from this chat are on again on this iPhone."
                             : "This chat's notifications arrive quietly on this iPhone.")
        }]
    }
}
#endif
