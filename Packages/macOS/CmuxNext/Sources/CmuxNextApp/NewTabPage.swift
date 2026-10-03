import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTabs
import Foundation
import os

/// What a new tab page does with the user's choice. The page is an agent
/// tab (it shows recent acpmux sessions and becomes a chat in place); a
/// terminal or browser choice replaces it with a tab of that kind.
struct NewTabPageHandler {
    /// `(page tab, kind, text, cwd)`: a terminal runs `text` (in `cwd` when
    /// the page picked a folder), a browser opens it as an address or a search.
    var open: (String, AgentPaneTabKind, String, String?) -> Void
    /// The location bar picked an open tab or workspace.
    var jump: (AgentPaneJumpTarget, String) -> Void
    var editShortcut: (AgentPaneTabKind) -> Void
    /// The page's "default: X" toggle wrote `tabs.newTabKind`.
    var setDefaultKind: (String) -> Void
    /// The page started a chat in place (Agent, Ask, or a recent session).
    var becameChat: () -> Void = {}
}

enum NewTabPage {
    static let action: ActionID = "newTab.page"
    /// Focus Location Bar (⌘L): the one place to type a URL, a command (`!`) or a question (`?`).
    static let focusLocation: ActionID = "focusLocation"

    /// Each kind's New action; the page shows their chords and edits them.
    static let newActions: [AgentPaneTabKind: ActionID] = [
        .terminal: "newSurface", .browser: "openBrowser", .agent: "palette.newAgentChat",
    ]

    /// The page's initially selected kind: the kind of the tab it opens
    /// from, a terminal in an empty pane.
    static func kind(selectedID: String?, selectedKind: TabKind?) -> AgentPaneTabKind {
        if selectedID?.hasPrefix(LocalAgentTab.prefix) == true { return .agent }
        if selectedID?.hasPrefix(LocalBrowserTab.prefix) == true || selectedKind == .browser { return .browser }
        return .terminal
    }

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
        return AgentPaneOmnibar(tabs: tabs, workspaces: workspaces, folders: folders, history: Array(history))
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
}

extension PaneController {
    /// New Tab Page: an agent tab showing the new tab page, beside the
    /// selected tab, with that tab's kind selected and folder inherited.
    func newTabPage() {
        let selectedID = stripModel.selectedID?.rawValue
        let cwd = selectedTab?.cwd
        let hotkeys = NewTabPage.newActions.compactMapValues { services.registry.shortcutDisplay(for: $0) }
        let page = AgentPaneNewTab(
            kind: NewTabPage.kind(selectedID: selectedID, selectedKind: selectedTab?.kind),
            hotkeys: hotkeys, cwd: cwd,
            location: selectedTab.flatMap { $0.kind == .browser ? $0.url : $0.cwd.map(NewTabPage.abbreviated) },
            omnibar: NewTabPage.omnibar(services, excluding: selectedID),
            defaultKind: (services.settings?.snapshot.newTabKind ?? NewTabDefaultKind.fallback).rawValue
        )
        let handler = NewTabPageHandler(
            open: { [weak self] key, kind, text, folder in
                self?.replaceNewTabPage(key, with: kind, text: text, cwd: folder ?? cwd)
            },
            jump: { [weak self] target, id in self?.jumpFromNewTabPage(target, id: id) },
            editShortcut: { [weak self] kind in self?.editNewTabShortcut(kind) },
            setDefaultKind: { [weak self] kind in self?.setNewTabDefaultKind(kind) },
            becameChat: { [weak self] in self?.services.newTabKinds.record(.agent, folder: cwd) }
        )
        let after = selectedID?.hasPrefix(LocalAgentTab.prefix) == true ? selectedID : nil
        showAgentTab(services.agentTabs.open(in: paneKey, of: daemon.store, after: after, newTab: (page, handler)))
    }

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

    /// The page chose a terminal or browser: open it, then close the page,
    /// which held nothing yet (the open-beside rule's one replace case). The
    /// page closes only once the new tab exists, so a refused or failed open
    /// leaves it, and what was typed, in place.
    private func replaceNewTabPage(_ key: String, with kind: AgentPaneTabKind, text: String, cwd: String?) {
        let closePage: @MainActor (SurfaceID) -> Void = { [weak self] _ in self?.close([StripTabID(key)]) }
        switch kind {
        case .terminal:
            guard let command = NewTabPage.command(text) else { return }
            services.newTabKinds.record(.terminal, folder: cwd)
            newTerminalTab(cwd: cwd, typing: command, then: closePage)
        case .browser:
            services.newTabKinds.record(.browser(engine: nil), folder: cwd)
            let url = services.cache.suggestionEngine.resolver.destination(for: text)?.url
            // A session-local browser tab is made and selected right away.
            if services.cache.browserTabs?.isAvailable() == true {
                newBrowserTab(url: url, then: closePage)
            } else {
                newBrowserTab(url: url)
                close([StripTabID(key)])
            }
        case .agent:
            return
        }
    }

    /// Through the palette's switchers, the one path that reveals a tab's or
    /// workspace's window and selects it.
    private func jumpFromNewTabPage(_ target: AgentPaneJumpTarget, id: String) {
        switch target {
        case .tab: PaletteSourcesBridge.TabSource(services: services).selectTab(id: id)
        case .workspace: PaletteSourcesBridge.WorkspaceSource(services: services).selectWorkspace(id: id)
        }
    }

    /// Through the schema, as the Settings window writes it; an unknown
    /// value from the page is ignored.
    private func setNewTabDefaultKind(_ value: String) {
        guard let kind = NewTabDefaultKind(rawValue: value), let settings = services.settings,
              let descriptor = SettingsSchema.descriptor(for: NewTabDefaultKind.configPath) else { return }
        Task {
            do { try await settings.setSetting(descriptor, to: .string(kind.rawValue)) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                    .error("new tab kind write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func editNewTabShortcut(_ kind: AgentPaneTabKind) {
        guard let id = NewTabPage.newActions[kind] else { return }
        services.palette.show(.keyboardShortcuts)
        services.palette.shortcutRecorder.begin(id)
    }
}
