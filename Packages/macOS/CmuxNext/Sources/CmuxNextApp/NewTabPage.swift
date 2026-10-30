import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextOnboarding
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTabs
import Foundation

/// What a new tab page does with the user's choice. The page is an agent
/// tab (it shows recent acpmux sessions and becomes a chat in place); a
/// terminal or browser choice replaces it with a tab of that kind.
struct NewTabPageHandler {
    /// `(page tab, request)`: a terminal runs or types the text (in its
    /// folder when the page picked one), a browser opens it as an address
    /// or searches it.
    var open: (String, AgentPaneOpenTab) -> Void
    var inputReady: (String, String) -> Void = { _, _ in }
    /// `(page tab, text)`: what `!` typed so far, for the terminal being made.
    var typeAhead: (String, String) -> Void = { _, _ in }
    /// The agent the screen picked, and the model picked on it, remembered on this Mac.
    var remember: (AgentPaneRememberedPick) -> Void = { _ in }
    /// The page's style switch picked a template (`tabs.newTabTemplate`), or its edit mode removed or
    /// moved a widget (`tabs.newTabWidgets.*`) or asked to add one.
    var edit: (AgentPaneNewTabEdit) -> Void = { _ in }
    /// The location bar picked an open tab or workspace.
    var jump: (AgentPaneJumpTarget, String) -> Void
    var editShortcut: (AgentPaneTabKind) -> Void
    /// The project picker fallback, resolved only when the user chooses Browse….
    var browseProject: () async -> String? = { nil }
    /// Returns recent projects, optionally filtered by the picker's query.
    var listProjects: (String?) async -> [String] = { _ in [] }
    /// Runs a host-owned action advertised by the omnibar.
    var action: (String) -> Void = { _ in }
}

enum NewTabPage {
    static let action: ActionID = "newTab.page"
    /// Focus Location Bar (⌘L): the one place to type a URL, a command (`!`) or a question (`?`).
    static let focusLocation: ActionID = "focusLocation"

    /// Each kind's New action; the page shows their chords and edits them.
    static let newActions: [AgentPaneTabKind: ActionID] = [
        .terminal: "newSurface", .browser: "openBrowser", .agent: "palette.newAgentChat",
    ]

    /// The page's initially selected kind: Agent chat, ready for the first prompt.
    static func kind(selectedID: String?, selectedKind: TabKind?) -> AgentPaneTabKind { .agent }

    /// `~/code/app` for a folder under the home folder, as the bar shows it.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The bar's suggestions: the open tabs and other workspaces a jump lands somewhere real on
    /// (``places(_:current:excluding:home:)``), the open tabs' folders (the current one first),
    /// and recent pages, newest first.
    static func omnibar(_ services: AppServices, excluding selectedID: String?, paletteActions: Bool = true) -> AgentPaneOmnibar {
        let (tabs, workspaces, folders) = places(services, excluding: selectedID)
        let history = services.cache.history(for: .default).entries.prefix(AgentPaneOmnibar.maximumEntries).map {
            AgentPaneOmnibar.Page(url: $0.url.absoluteString, title: $0.title, icon: AppServices.dataURL(services.siteFavicon($0.url, profile: .default)))
        }
        let commands = services.history.commands.entries().prefix(AgentPaneOmnibar.maximumEntries).compactMap(\.title)
        // Every Commands palette (Cmd-Shift-P) action, from the palette's own rows (one source).
        let actions = paletteActions ? Self.paletteActions(services) : []
        return AgentPaneOmnibar(
            tabs: tabs, workspaces: workspaces, folders: folders, projects: folders, actions: actions, commands: Array(commands), history: Array(history)
        )
    }

    /// Every Commands palette (Cmd-Shift-P) action as the bar lists it, from the palette's own rows.
    static func paletteActions(_ services: AppServices) -> [AgentPaneOmnibar.Action] {
        BenchSpans.measure("newTab.paletteActions") {
            services.palette.commandEntries().map {
                AgentPaneOmnibar.Action(id: $0.id.rawValue, title: $0.title, detail: $0.section, keywords: $0.keywords,
                                        keycaps: $0.keycaps.isEmpty ? nil : $0.keycaps)
            }
        }
    }

    /// One workspace as the bar reads it.
    struct PlaceSource {
        var id: String
        var name: String
        var tabs: [TabModel]
    }

    /// ``places(_:current:excluding:home:icon:)`` over every machine's workspaces; `current` is
    /// the workspace the page's window shows (the active window's when nil).
    static func places(_ services: AppServices, excluding selectedID: String?, current: String? = nil)
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        let sources = services.machines.allWorkspaces.map { workspace, _ in
            PlaceSource(id: workspace.id, name: workspace.displayName, tabs: workspace.screens.flatMap(\.panes).flatMap(\.tabs))
        }
        let current = current ?? services.windows.active?.state.workspaceID
        return places(sources, current: current, excluding: selectedID, home: NSHomeDirectory()) {
            AppServices.dataURL(services.tabFavicon($0))
        }
    }

    /// The open tabs, other workspaces and folders the bar suggests: only places a jump lands
    /// somewhere real on (Leo 2026-10-11: "about:blank Home", a bare "~ ~" folder, each
    /// workspace twice). A New Tab page, a page tab and a blank browser tab are no place; a chat
    /// is one; the home folder is not a project. Another workspace with one place lists once, as
    /// that tab: a row that reads as a tab jumps to the tab (Leo 2026-10-19).
    static func places(_ workspaces: [PlaceSource], current: String?, excluding selectedID: String?, home: String,
                       icon: (TabModel) -> String? = { _ in nil })
        -> (tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace], folders: [String]) {
        var tabs: [AgentPaneOmnibar.Tab] = []
        var others: [AgentPaneOmnibar.Workspace] = []
        var folders: [String] = []
        for workspace in workspaces {
            for folder in workspace.tabs.compactMap(\.cwd) where folder != home && !folders.contains(folder) { folders.append(folder) }
            let rows = workspace.tabs.filter { $0.id != selectedID }.compactMap { tab in
                place(tab, home: home).map { place in
                    AgentPaneOmnibar.Tab(id: tab.id, kind: place.kind, title: place.title, detail: place.detail,
                                         workspace: workspace.name, icon: place.kind == .browser ? icon(tab) : nil)
                }
            }
            tabs += rows
            // Another workspace's only place is that tab's row (Switch to tab lands on it), not the workspace's.
            guard workspace.id != current, rows.count != 1 else { continue }
            let detail = workspace.tabs.lazy.compactMap(\.cwd).first.map { abbreviated($0, home: home) }
            others.append(AgentPaneOmnibar.Workspace(id: workspace.id, name: workspace.name, detail: detail))
        }
        return (tabs, others, folders)
    }

    /// A tab as a bar row: its kind, a title of its own and the line under it; nil for no place.
    static func place(_ tab: TabModel, home: String) -> (kind: AgentPaneTabKind, title: String, detail: String?)? {
        let title = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = !title.isEmpty && title != blankPage
        switch tab.kind {
        case .browser:
            // A browser on `about:blank` is no place, whatever its title says ("about:blank Home").
            guard let url = tab.url.flatMap({ $0 == blankPage || $0.isEmpty ? nil : displayURL($0) }) else { return nil }
            let shown = named ? title : url
            return (.browser, shown, url == shown ? nil : url)
        case .pty, .remoteTerminal:
            let folder = tab.cwd.map { abbreviated($0, home: home) }
            // A shell titled with its folder alone is named by that folder.
            let shown = named && title != tab.cwd && title != folder ? title : folder ?? (named ? title : nil)
            guard let shown else { return nil }
            return (.terminal, shown, folder == shown ? nil : folder)
        case .conversation:
            // A chat (an agent session) is a place; a New Tab page (no session yet) and a page tab are not.
            guard tab.agentSession?.session != nil, named else { return nil }
            return (.agent, title, tab.cwd.map { abbreviated($0, home: home) })
        case .other:
            return nil
        }
    }

    /// The address of a page with nothing on it, the title a New Tab page starts with.
    static let blankPage = "about:blank"

    /// `vite.dev/guide` for `https://vite.dev/guide/`.
    static func displayURL(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The command line a terminal choice types: nil for an empty field,
    /// else the text run with a newline. The page's field is one line, so
    /// text with a line break is refused rather than run as several commands.
    static func command(_ text: String) -> String?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: \.isNewline) { return .none }
        return .some(trimmed.isEmpty ? nil : trimmed + "\n")
    }

    /// The page a new tab shows beside `selected`: its folder inherited and
    /// the location bar's suggestions, with the field empty.
    /// `window` is where the page shows (the active one when nil; a panel counts as the window
    /// that owns it): its dots' last pick comes first, then the saved `tabs.newTabTemplate` (cx-l1jv).
    static func page(_ services: AppServices, selected: TabModel?, window: NSWindow? = nil,
                     pane: PaneController? = nil, machine: DaemonService? = nil,
                     paletteActions: Bool = true) -> AgentPaneNewTab {
        let selectedID = selected?.id
        let hotkeys = newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) }
        // An SSH or Cloud tab's page shows that machine's folder, never this Mac's home (cx-gaq9).
        let machine = NewTabPageMachine(services, selected: selected, pane: pane, machine: machine)
        var bar = omnibar(services, excluding: selectedID, paletteActions: paletteActions)
        // A page on another machine offers that machine's folders only (cx-k21v).
        if let remote = machine.remoteFolders { (bar.folders, bar.projects) = (remote, remote) }
        return AgentPaneNewTab(
            kind: kind(selectedID: selectedID, selectedKind: selected?.kind),
            // The source tab's folder is what the page's chat or terminal starts in; the field
            // itself always starts empty, with its placeholder (never `~` or a URL).
            hotkeys: hotkeys, cwd: machine.cwd,
            omnibar: bar,
            projects: machine.remoteFolders ?? projects(services),
            layout: NewTabTunables.layout.value.pageLayout,
            lastAgent: services.newTabChoices.agent, lastPicks: services.newTabChoices.picks,
            home: machine.home,
            template: services.settings?.snapshot.newTabTemplate?.rawValue, pageWidgets: services.settings?.snapshot.newTabWidgets.ids
        ).dismissingHarnessHint(services.newTabChoices.harnessHintDismissed).listingAllChats(showsAllChats(services))
            .turningHeadlineOff(services.settings?.snapshot.newTabWidgets)
            .startingIn(machine.remoteFolders == nil ? services.newTabChoices.startedProject : nil)
            .warmedOnThisMac(machine.remoteFolders == nil)
            .withWeather(services)
    }

    /// What a prewarmed spare page loads with before Cmd-T adopts it
    /// (NewTabSparePool): the design and remembered choices; no tab context.
    static func sparePage(_ services: AppServices) -> AgentPaneNewTab {
        AgentPaneNewTab(
            kind: .agent, hotkeys: newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) },
            layout: NewTabTunables.layout.value.pageLayout, lastAgent: services.newTabChoices.agent,
            lastPicks: services.newTabChoices.picks, home: NSHomeDirectory(),
            template: services.settings?.snapshot.newTabTemplate?.rawValue, pageWidgets: services.settings?.snapshot.newTabWidgets.ids
        ).dismissingHarnessHint(services.newTabChoices.harnessHintDismissed).listingAllChats(showsAllChats(services))
            .turningHeadlineOff(services.settings?.snapshot.newTabWidgets)
            .startingIn(services.newTabChoices.startedProject).warmedOnThisMac()
            .withWeather(services)
    }

    /// Show All Chats on New Tab (`sidebar.showChats`; All chats left the sidebar for this page, cx-n0i9).
    static func showsAllChats(_ services: AppServices) -> Bool { services.settings?.snapshot.sidebarSections.showChats ?? true }

    /// Startup folders only without `project-list-v1`; else the page asks `project.list` (removals win, cx-m0p7).
    static func projects(_ services: AppServices) -> [String] { services.machines.local.projectStore == nil ? services.onboarding.projectFolders : [] }

    /// The page's handler: `open` is the pane's (it replaces the page with
    /// a tab); the location bar's jumps, the shortcut and default-kind edits
    /// and the chat record go through `services`.
    static func handler(_ services: AppServices, cwd: String?,
                        open: @escaping (String, AgentPaneOpenTab) -> Void) -> NewTabPageHandler {
        NewTabPageHandler(
            open: open,
            typeAhead: { [weak services] key, text in services?.newTabTypeAhead.update(key, text: text) },
            remember: { [weak services] pick in services?.newTabChoices.remember(pick) },
            edit: { [weak services] edit in if let services { self.edit(edit, services: services) } },
            jump: { [weak services] target, id in if let services { jump(target, id: id, services: services) } },
            editShortcut: { [weak services] kind in if let services { editShortcut(kind, services: services) } },
            browseProject: { [weak services] in
                guard let services, let path = await NewTabPage.chooseFolder(in: services.windows.active?.window)?.path else { return nil }
                return await services.machines.local.projectStore?.picked(path) ?? path
            },
            listProjects: { [weak services] query in
                guard let services else { return [] }
                if let paths = await services.machines.local.projectStore?.pickerPaths(query: query, limit: AgentPaneOmnibar.maximumEntries) { return paths }
                let hints = services.history.agents.sessions.compactMap(\.cwd) + services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd)
                return await Task.detached {
                    RecentProjectScan.live().complete(query: query ?? "", hints: hints, limit: AgentPaneOmnibar.maximumEntries)
                }.value
            },
            action: { [weak services] id in
                // As the palette runs its row: an action that needs arguments asks for them there.
                services?.palette.runCommand(ActionID(rawValue: id), relativeTo: services?.windows.active?.window)
            }
        )
    }

    /// Through the palette's switchers, the one path that reveals a tab's or
    /// workspace's window and selects it.
    static func jump(_ target: AgentPaneJumpTarget, id: String, services: AppServices) {
        // Back returns to this page (Leo 2026-10-06).
        services.locationTrail.noteJump()
        switch target {
        case .tab: PaletteSourcesBridge.TabSource(services: services).selectTab(id: id)
        case .workspace: PaletteSourcesBridge.WorkspaceSource(services: services).selectWorkspace(id: id)
        case .here: break // only a split's page lists tabs to move (NewTabPage.split)
        case .closed: NewTabClosed.reopen(id, services: services)
        }
    }

    /// The style switch's pick, the edit mode's ✕ and drag and the dots' quick actions, written as Settings would (a refusal is
    /// logged; the next New Tab shows what the file says); + opens Settings on the widget rows
    /// (the widgets are settings, not store items: extensibility-DESIGN.md).
    static func edit(_ edit: AgentPaneNewTabEdit, services: AppServices) {
        guard let settings = services.settings else { return }
        switch edit {
        case .template(let template): Task { await settings.saveNewTabTemplate(template) }
        case .remove(let widget): Task { await settings.logged("new tab widget") { try await settings.removeNewTabWidget(widget) } }
        case .show(let widget): Task { await settings.logged("new tab widget") { try await settings.showNewTabWidget(widget) } }
        case .order(let order): Task { await settings.logged("new tab widget order") { try await settings.setNewTabWidgetOrder(order) } }
        case .add: try? services.settingsWindow.show(section: nil, setting: "tabs.newTabWidgets.greeting", focus: true)
        }
    }

    static func editShortcut(_ kind: AgentPaneTabKind, services: AppServices) {
        guard let id = newActions[kind] else { return }
        services.palette.show(.keyboardShortcuts)
        services.palette.shortcutRecorder.begin(id)
    }
}

extension PaneController {
    /// New Tab Page: an agent tab showing the new tab page, where the store
    /// places a new tab, with the selected tab's kind selected and folder inherited
    /// (``NewTabPage/open(in:seed:reusingShown:then:)``).
    /// `then` gets the new tab's id once the store made it.
    /// `reusingShown`: see ``NewTabPage/open(in:seed:reusingShown:then:)``.
    func newTabPage(seed: AgentPaneSeedSource? = nil, reusingShown: Bool = false, then: (@MainActor (String) -> Void)? = nil) {
        NewTabPage.open(in: self, seed: seed, reusingShown: reusingShown, then: then)
    }

    /// Focus Location Bar: a browser tab's address bar; on a New Tab page its own (React) field; in
    /// an agent chat its composer; anywhere else a new New Tab page, whose field takes the keyboard
    /// (cx-e2aa; Lawrence 2026-10-10: the New Tab page is React only, no native omnibar row). ⌃L
    /// stays the terminal's (clear screen).
    func focusLocation(_ invocation: ActionInvocation) {
        if case .browser = currentContent {
            _ = services.registry.perform("focusBrowserAddressBar", invocation: invocation)
            return
        }
        // A Markdown tab has the browser's omnibar row above its page (markdown-omnibar-DESIGN.md).
        if case .page(let view) = currentContent, let bar = view.topBar as? MarkdownOmnibarBar {
            bar.focusLocation()
            return
        }
        // An agent chat: its composer takes the keyboard, not a new New Tab page beside it.
        if case .agent(let view) = currentContent, view.model.newTab == nil {
            view.focusComposer()
            return
        }
        // `open` focuses the field of a New Tab page already showing, else opens one. In a pane
        // of another machine it is the same page; nothing starts there before a send (cx-k21v).
        NewTabPage.open(in: self, seed: nil, reusingShown: true)
    }
}

extension AgentPaneNewTab {
    /// The page with Integrate a harness off when it was dismissed for good.
    func dismissingHarnessHint(_ dismissed: Bool) -> AgentPaneNewTab {
        var page = self
        page.harnessHintDismissed = dismissed ? true : nil
        return page
    }

    /// The page with the project of the chat the person last picked and started, if any.
    func startingIn(_ startedProject: String?) -> AgentPaneNewTab {
        var page = self
        page.startedProject = startedProject
        return page
    }

    /// The page with All chats left out (recent chats only) when Show All Chats on New Tab is off.
    func listingAllChats(_ shown: Bool) -> AgentPaneNewTab {
        var page = self
        page.allChats = shown ? nil : false
        return page
    }

    /// The page told that `tabs.newTabWidgets.greeting` is set to false (``AgentPaneNewTab/headlineOff``).
    func turningHeadlineOff(_ widgets: NewTabWidgetSettings?) -> AgentPaneNewTab {
        var page = self
        page.headlineOff = widgets?.greetingTurnedOff == true ? true : nil
        return page
    }
}
