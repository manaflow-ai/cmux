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
import os

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
    /// The agent the screen picked, remembered on this Mac.
    var remember: (String) -> Void = { _ in }
    /// The location bar picked an open tab or workspace.
    var jump: (AgentPaneJumpTarget, String) -> Void
    var editShortcut: (AgentPaneTabKind) -> Void
    /// The page's "default: X" toggle wrote `tabs.newTabKind`.
    var setDefaultKind: (String) -> Void
    /// The page's template dots picked a template, saved as `tabs.newTabTemplate`.
    var setTemplate: (String) -> Void = { _ in }
    /// The page started a chat in place (Agent, Ask, or a recent session).
    var becameChat: () -> Void = {}
    /// The project picker fallback, resolved only when the user chooses Browse….
    var browseProject: () async -> String? = { nil }
    /// Returns recent projects, optionally filtered by the picker's query.
    var listProjects: (String?) async -> [String] = { _ in [] }
    /// Runs a host-owned action advertised by the omnibar.
    var action: (String) -> Void = { _ in }

    /// The page's setting writes (`AgentPaneModel.onNewTabSetting`).
    func write(_ setting: AgentPaneNewTabSetting) {
        switch setting {
        case .defaultKind(let kind): setDefaultKind(kind)
        case .template(let template): setTemplate(template)
        }
    }
}

enum NewTabPage {
    static let action: ActionID = "newTab.page"
    /// Focus Location Bar (⌘L): the one place to type a URL, a command (`!`) or a question (`?`).
    static let focusLocation: ActionID = "focusLocation"

    /// Each kind's New action; the page shows their chords and edits them.
    static let newActions: [AgentPaneTabKind: ActionID] = [
        .terminal: "newSurface", .browser: "openBrowser", .agent: "palette.newAgentChat",
    ]

    /// The New Tab Tools cards are projections of the action catalog. The
    /// registry supplies both availability and the user-visible shortcut.
    static func tools(_ services: AppServices, targetID: String? = nil) -> [AgentPaneNewTab.Tool] {
        let specs: [(ActionID, String, String, [ActionID])] = [
            ("openDiffViewer", "newTabPage.tool.changes", "plusminus", []),
            ("newSurface", "newTabPage.tool.terminal", "terminal", ["splitRight", "splitDown"]),
            ("file.open", "newTabPage.tool.files", "folder", []),
            ("agentPane.searchChats", "newTabPage.tool.sideChat", "bubble.left.and.text.bubble.right", []),
        ]
        return specs.compactMap { id, title, symbol, menu in
            guard services.registry.canPerform(id) else { return nil }
            if let targetID {
                let target = ActionTargetRef(kind: .tab, id: targetID)
                guard ActionTargetReasons.canPerform(id, invocation: ActionInvocation(target: target), in: services.registry) else { return nil }
            }
            return AgentPaneNewTab.Tool(id: id.rawValue, title: title, symbol: symbol,
                                        shortcut: services.registry.shortcutDisplay(for: id), menu: menu.map(\.rawValue))
        }
    }

    /// The page's initially selected kind: Agent chat, ready for the first prompt.
    static func kind(selectedID: String?, selectedKind: TabKind?) -> AgentPaneTabKind { .agent }

    /// `~/code/app` for a folder under the home folder, as the bar shows it.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The bar's suggestions: every open terminal and browser tab but the one
    /// the page opened from, the other workspaces, the open tabs' folders
    /// (the current one first), and recent pages, newest first.
    static func omnibar(_ services: AppServices, excluding selectedID: String?) -> AgentPaneOmnibar {
        let current = services.windows.active?.state.workspaceID
        var tabs: [AgentPaneOmnibar.Tab] = []
        var workspaces: [AgentPaneOmnibar.Workspace] = []
        var folders: [String] = []
        for (workspace, _) in services.machines.allWorkspaces {
            let workspaceTabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            for tab in workspaceTabs {
                if let folder = tab.cwd, !folders.contains(folder) { folders.append(folder) }
                // Terminals and pages only: a conversation tab (every New
                // Tab page) or a page tab would list as "about:blank"
                // terminals (cx-7cit9).
                guard tab.id != selectedID, [.pty, .remoteTerminal, .browser].contains(tab.kind) else { continue }
                let browser = tab.kind == .browser
                tabs.append(AgentPaneOmnibar.Tab(
                    id: tab.id, kind: browser ? .browser : .terminal, title: tab.displayTitle,
                    detail: browser ? tab.url.map(Self.displayURL) : tab.cwd.map(abbreviated), workspace: workspace.displayName,
                    icon: browser ? AppServices.dataURL(services.tabFavicon(tab)) : nil
                ))
            }
            if workspace.id != current {
                workspaces.append(AgentPaneOmnibar.Workspace(
                    id: workspace.id, name: workspace.displayName,
                    detail: workspaceTabs.lazy.compactMap(\.cwd).first.map(abbreviated)
                ))
            }
        }
        let history = services.cache.history(for: .default).entries.prefix(AgentPaneOmnibar.maximumEntries).map {
            AgentPaneOmnibar.Page(url: $0.url.absoluteString, title: $0.title, icon: AppServices.dataURL(services.siteFavicon($0.url, profile: .default)))
        }
        let commands = services.history.commands.entries().prefix(AgentPaneOmnibar.maximumEntries).compactMap(\.title)
        let actionIDs: Set<String> = ["palette.openCmuxSettingsFile", "keybindings.open"]
        let actions = services.registry.descriptors.filter { actionIDs.contains($0.id.rawValue) }.map {
            AgentPaneOmnibar.Action(id: $0.id.rawValue, title: $0.title, keywords: $0.keywords)
        }
        return AgentPaneOmnibar(
            tabs: tabs, workspaces: workspaces, folders: folders, projects: folders, actions: actions, commands: Array(commands), history: Array(history)
        )
    }

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
                     pane: PaneController? = nil) -> AgentPaneNewTab {
        let selectedID = selected?.id
        let hotkeys = newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) }
        // An SSH or Cloud tab's page shows that machine's folder, never this Mac's home (cx-gaq9).
        let machine = NewTabPageMachine(services, selected: selected, pane: pane)
        var bar = omnibar(services, excluding: selectedID)
        // A page on another machine offers that machine's folders only (cx-k21v).
        if let remote = machine.remoteFolders { (bar.folders, bar.projects) = (remote, remote) }
        return AgentPaneNewTab(
            kind: kind(selectedID: selectedID, selectedKind: selected?.kind),
            // The source tab's folder is what the page's chat or terminal starts in; the field
            // itself always starts empty, with its placeholder (never `~` or a URL).
            hotkeys: hotkeys, cwd: machine.cwd,
            omnibar: bar,
            projects: machine.remoteFolders ?? projects(services),
            defaultKind: (services.settings?.snapshot.newTabKind ?? NewTabDefaultKind.fallback).rawValue,
            layout: NewTabTunables.layout.value.pageLayout,
            lastAgent: services.newTabChoices.agent,
            home: machine.home, tools: tools(services, targetID: selected?.id),
            template: (services.newTabChoices.template(in: (window.flatMap { services.windows.owner(of: $0) } ?? services.windows.active)?.window)
                ?? services.settings?.snapshot.newTabTemplate)?.rawValue,
            templateSwitcher: NewTabTunables.templateSwitcher.value ? true : nil
        )
    }

    /// What a prewarmed spare page loads with before Cmd-T adopts it
    /// (NewTabSparePool): the design and remembered choices; no tab context.
    static func sparePage(_ services: AppServices) -> AgentPaneNewTab {
        AgentPaneNewTab(
            kind: .agent, hotkeys: newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) },
            layout: NewTabTunables.layout.value.pageLayout, lastAgent: services.newTabChoices.agent, home: NSHomeDirectory(),
            tools: tools(services), template: services.settings?.snapshot.newTabTemplate?.rawValue,
            templateSwitcher: NewTabTunables.templateSwitcher.value ? true : nil
        )
    }

    /// Projects discovered off the main actor during app startup. The current
    /// session cwd still arrives immediately from the pane handshake.
    static func projects(_ services: AppServices) -> [String] { services.onboarding.projectFolders }

    /// The page's handler: `open` is the pane's (it replaces the page with
    /// a tab); the location bar's jumps, the shortcut and default-kind edits
    /// and the chat record go through `services`.
    static func handler(_ services: AppServices, cwd: String?,
                        open: @escaping (String, AgentPaneOpenTab) -> Void) -> NewTabPageHandler {
        NewTabPageHandler(
            open: open,
            typeAhead: { [weak services] key, text in services?.newTabTypeAhead.update(key, text: text) },
            remember: { [weak services] agent in services?.newTabChoices.remember(agent: agent) },
            jump: { [weak services] target, id in if let services { jump(target, id: id, services: services) } },
            editShortcut: { [weak services] kind in if let services { editShortcut(kind, services: services) } },
            setDefaultKind: { [weak services] kind in if let services { setDefaultKind(kind, services: services) } },
            setTemplate: { [weak services] template in if let services { setTemplate(template, services: services) } },
            becameChat: { [weak services] in services?.newTabKinds.record(.agent, folder: cwd) },
            browseProject: { [weak services] in
                guard let services else { return nil }
                return await NewTabPage.chooseFolder(in: services.windows.active?.window)?.path
            },
            listProjects: { [weak services] query in
                guard let services else { return [] }
                let hints = services.history.agents.sessions.compactMap(\.cwd) + services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd)
                return await Task.detached {
                    RecentProjectScan.live().complete(query: query ?? "", hints: hints, limit: AgentPaneOmnibar.maximumEntries)
                }.value
            },
            action: { [weak services] id in
                guard let services else { return }
                _ = services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .user))
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

    /// Through the schema, as the Settings window writes it; an unknown
    /// value from the page is ignored.
    static func setDefaultKind(_ value: String, services: AppServices) {
        guard let kind = NewTabDefaultKind(rawValue: value), let settings = services.settings,
              let descriptor = SettingsSchema.descriptor(for: NewTabDefaultKind.configPath) else { return }
        Task {
            do { try await settings.setSetting(descriptor, to: .string(kind.rawValue), by: .caller("page")) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                    .error("new tab kind write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The template dots: remembered for the window they were picked in (the active one), and
    /// saved through the schema, as the Settings window writes it, for windows that picked none.
    /// An unknown value from the page is ignored.
    static func setTemplate(_ value: String, services: AppServices) {
        guard let template = NewTabTemplate(rawValue: value) else { return }
        services.newTabChoices.remember(template: template, in: services.windows.active?.window)
        guard let settings = services.settings, let descriptor = SettingsSchema.descriptor(for: NewTabTemplate.configPath) else { return }
        Task {
            do { try await settings.setSetting(descriptor, to: .string(template.rawValue), by: .caller("page")) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                    .error("new tab template write failed: \(String(describing: error), privacy: .public)")
            }
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
    /// (``NewTabPage/open(in:seed:)``).
    /// `then` gets the new tab's id once the store made it.
    func newTabPage(seed: AgentPaneSeedSource? = nil, then: (@MainActor (String) -> Void)? = nil) { NewTabPage.open(in: self, seed: seed, then: then) }

    /// Focus Location Bar: a browser tab's address bar; on a New Tab page its own (React) field;
    /// anywhere else a new New Tab page, whose field takes the keyboard (cx-e2aa; Lawrence
    /// 2026-10-10: the New Tab page is React only, no native omnibar row). ⌃L stays the
    /// terminal's (clear screen).
    func focusLocation(_ invocation: ActionInvocation) {
        if case .browser = currentContent {
            _ = services.registry.perform("focusBrowserAddressBar", invocation: invocation)
            return
        }
        // `open` focuses the field of a New Tab page already showing, else opens one. In a pane
        // of another machine it is the same page; nothing starts there before a send (cx-k21v).
        NewTabPage.open(in: self, seed: nil)
    }
}
