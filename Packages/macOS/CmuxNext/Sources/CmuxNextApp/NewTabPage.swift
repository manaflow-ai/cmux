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
    /// `(page tab, text)`: what `!` typed so far, for the terminal being made.
    var typeAhead: (String, String) -> Void = { _, _ in }
    /// The agent the screen picked, remembered on this Mac.
    var remember: (String) -> Void = { _ in }
    /// The location bar picked an open tab or workspace.
    var jump: (AgentPaneJumpTarget, String) -> Void
    var editShortcut: (AgentPaneTabKind) -> Void
    /// The page's "default: X" toggle wrote `tabs.newTabKind`.
    var setDefaultKind: (String) -> Void
    /// The page started a chat in place (Agent, Ask, or a recent session).
    var becameChat: () -> Void = {}
    /// The project picker fallback, resolved only when the user chooses Browse….
    var browseProject: () async -> String? = { nil }
    /// Returns recent projects, optionally filtered by the picker's query.
    var listProjects: (String?) async -> [String] = { _ in [] }
    /// Opens the existing onboarding import and project/history sync flow.
    var importAndSync: () -> Void = {}
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
                guard tab.id != selectedID else { continue }
                let browser = tab.kind == .browser
                tabs.append(AgentPaneOmnibar.Tab(
                    id: tab.id, kind: browser ? .browser : .terminal, title: tab.displayTitle,
                    detail: browser ? tab.url.map(Self.displayURL) : tab.cwd.map(abbreviated), workspace: workspace.displayName
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
            AgentPaneOmnibar.Page(url: $0.url.absoluteString, title: $0.title)
        }
        let commands = services.history.commands.entries().prefix(AgentPaneOmnibar.maximumEntries).compactMap(\.title)
        let actionIDs: Set<String> = ["palette.welcomeChecklist", "palette.openCmuxSettingsFile", "keybindings.open"]
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

    /// The page a new tab shows beside `selected`: that tab's kind
    /// selected, its folder inherited, and the location bar's suggestions.
    static func page(_ services: AppServices, selected: TabModel?) -> AgentPaneNewTab {
        let selectedID = selected?.id
        let hotkeys = newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) }
        return AgentPaneNewTab(
            kind: kind(selectedID: selectedID, selectedKind: selected?.kind),
            hotkeys: hotkeys, cwd: selected?.cwd,
            location: selected.flatMap { $0.kind == .browser ? $0.url : $0.cwd.map(abbreviated) },
            omnibar: omnibar(services, excluding: selectedID),
            projects: projects(services),
            defaultKind: (services.settings?.snapshot.newTabKind ?? NewTabDefaultKind.fallback).rawValue,
            layout: NewTabTunables.layout.value.pageLayout,
            lastAgent: services.newTabChoices.agent,
            home: NSHomeDirectory()
        )
    }

    /// What a prewarmed spare page loads with before Cmd-T adopts it
    /// (NewTabSparePool): the design and remembered choices; no tab context.
    static func sparePage(_ services: AppServices) -> AgentPaneNewTab {
        AgentPaneNewTab(
            kind: .agent, hotkeys: newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) },
            layout: NewTabTunables.layout.value.pageLayout, lastAgent: services.newTabChoices.agent, home: NSHomeDirectory()
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
            becameChat: { [weak services] in services?.newTabKinds.record(.agent, folder: cwd) },
            browseProject: { [weak services] in
                guard let services else { return nil }
                return await AppOnboardingServices(owner: services.onboarding).chooseFolder()?.path
            },
            listProjects: { [weak services] query in
                guard let services else { return [] }
                let hints = services.history.agents.sessions.compactMap(\.cwd) + services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).compactMap(\.cwd)
                return await Task.detached {
                    RecentProjectScan.live().complete(query: query ?? "", hints: hints, limit: AgentPaneOmnibar.maximumEntries)
                }.value
            },
            importAndSync: { [weak services] in services?.onboarding.show(step: .projects) },
            action: { [weak services] id in
                guard let services else { return }
                _ = services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .user))
            }
        )
    }

    /// Through the palette's switchers, the one path that reveals a tab's or
    /// workspace's window and selects it.
    static func jump(_ target: AgentPaneJumpTarget, id: String, services: AppServices) {
        switch target {
        case .tab: PaletteSourcesBridge.TabSource(services: services).selectTab(id: id)
        case .workspace: PaletteSourcesBridge.WorkspaceSource(services: services).selectWorkspace(id: id)
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
    func newTabPage(seed: AgentPaneSeedSource? = nil) { NewTabPage.open(in: self, seed: seed) }

    /// Focus Location Bar: a browser tab's address bar; the field of a new tab
    /// page already showing; anywhere else a new tab page, whose field takes
    /// the keyboard. ⌃L stays the terminal's (clear screen).
    func focusLocation(_ invocation: ActionInvocation) {
        if case .browser = currentContent {
            _ = services.registry.perform("focusBrowserAddressBar", invocation: invocation)
        } else if let key = currentTabKey, services.agentTabs.isNewTabPage(key) {
            services.windowController(showing: self)?.focus.send(.focusPane(paneKey, source: .intent))
            services.agentTabs.view(for: key)?.focusLocation()
        } else {
            newTabPage()
        }
    }
}

/// Runs a new tab page's close on the frame after its replacement shows.
@MainActor private let closeFrame = FrameBatcher(owner: "NewTabPage.close")

extension NewTabPage {
    /// The New Tab page in `pane`, adopting the window's prewarmed spare when it has one
    /// (NewTabSparePool), else loading cold. A static of the page, not the pane (the godfile
    /// limit counts PaneController's extensions). Everything happens in this one main-actor
    /// turn, with no hop: the spare waited at this pane's content size, so its adoption changes
    /// no size and WebKit shows the page at its final layout; the strip shows the tab now at full
    /// width; and the turn's one commit puts the tab and the page on screen in the same frame.
    static func open(in pane: PaneController, seed: AgentPaneSeedSource?) {
        let start = ContinuousClock.now
        let services = pane.services
        let cwd = pane.selectedTab?.cwd
        let page = Self.page(services, selected: pane.selectedTab)
        let handler = Self.handler(services, cwd: cwd) { [weak pane] key, request in
            if let pane { BenchSpans.measure("newTab.replace") { Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: pane) } }
        }
        let spare = seed == nil
            ? BenchSpans.measure("newTab.take", { services.newTabSpares.take(for: pane.view.window, size: pane.view.contentHost.bounds.size) })
            : nil
        // The tab shows at once (a store intent); the store's tab replaces it when it answers.
        guard BenchSpans.measure("newTab.open", { pane.openAgentTab(seed: seed, newTab: (page, handler), spare: spare?.view) }) else { return }
        // The adopted page is alive: show it this frame and give it the keyboard now, so the
        // first key typed after the open reaches its field (fleet test: it went to the old responder).
        if spare != nil, services.presentation.showNow(pane) {
            services.windowController(showing: pane)?.focus.send(.focusPane(pane.paneKey, source: .intent))
        }
        BenchSpans.measure("newTab.strip") { pane.view.stripView.sync(fromModel: true, motion: false) }
        services.newTabSpares.record(.init(spare: spare != nil, crossWindow: spare?.crossWindow == true,
                                           milliseconds: NewTabSparePool.milliseconds(since: start), refit: spare?.refit == true))
    }

    /// The page chose a terminal or browser: open it, then close the page,
    /// which held nothing yet (the open-beside rule's one replace case). The
    /// page closes only once the new tab exists, so a refused or failed open
    /// leaves it, and what was typed, in place.
    /// A static of the page, not the pane, so PaneController stays one
    /// responsibility (the godfile limit counts its extensions).
    static func replace(_ key: String, with request: AgentPaneOpenTab, cwd: String?, in pane: PaneController) {
        let services = pane.services
        // The page closes one frame after the new tab shows, so the frame that builds the
        // terminal surface does not also pay for the page (R81: 17.8 ms frames at 120 Hz).
        let closePage: @MainActor (SurfaceID) -> Void = { [weak pane] _ in
            closeFrame.scheduleFrame { BenchSpans.measure("newTab.closePage") { pane?.close([StripTabID(key)]) } }
        }
        switch request.kind {
        case .terminal where !request.run:
            // `!` on the screen: type, never run; keys typed while the
            // terminal is made follow it in order (NewTabTypeAhead).
            services.newTabKinds.record(.terminal, folder: cwd)
            let typeAhead = services.newTabTypeAhead
            if typeAhead.latest(key).isEmpty, !request.text.isEmpty { typeAhead.update(key, text: request.text) }
            pane.newTerminalTab(cwd: cwd, typingAhead: key, then: closePage)
        case .terminal:
            guard let command = command(request.text) else { return }
            services.newTabKinds.record(.terminal, folder: cwd)
            pane.newTerminalTab(cwd: cwd, typing: command, then: closePage)
        case .browser:
            services.newTabKinds.record(.browser(engine: nil), folder: cwd)
            let resolver = services.cache.suggestionEngine.resolver
            let url = request.search
                ? resolver.searchEngine.searchURL(for: request.text.trimmingCharacters(in: .whitespacesAndNewlines))
                : resolver.destination(for: request.text)?.url
            // A session-local browser tab is made and selected right away.
            if services.cache.browserTabs?.isAvailable() == true {
                pane.newBrowserTab(url: url, then: closePage)
            } else {
                pane.newBrowserTab(url: url)
                pane.close([StripTabID(key)])
            }
        case .agent:
            return
        }
    }
}
