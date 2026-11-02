import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// "Workspaces as tabs" (Leo, relayed 2026-10-21; `sidebar.workspacesAsTabs`, a Debug tunable,
/// off): "a Claude-desktop-style compact list (one line per workspace, title + status/PR badge +
/// needs-you icon; no second line). ⌘⇧[ and ⌘⇧] move to the previous/next workspace in sidebar
/// order, wrapping, across groups, like switching tabs." Off, nothing changes: Cmd-Shift-[ / ]
/// cycle the focused pane's tabs (Lawrence 2026-10-15), and Home keeps its keys either way.
@MainActor @Suite struct WorkspacesAsTabsTests {
    /// The app's catalog and default bindings with the tunable `on` or off (`includesWorkspaceTabKeys`).
    static func registry(on: Bool) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["nextSurface", "prevSurface", "nextSidebarTab", "prevSidebarTab"] {
            registry.bind(id, invoke: { _ in })
        }
        registry.includesWorkspaceTabKeys = { on }
        return registry
    }

    static let on = registry(on: true), off = registry(on: false)

    /// The command `keys` run in `surface`, with the toggle's context key when `tabs`, and its `scope` argument.
    static func winner(_ keys: String, in surface: String, tabs: Bool) -> (command: String?, scope: String?) {
        var context = KeyContext([KeyContext.surfaceKind: .string(surface)])
        if tabs { context[KeyContext.workspacesAsTabs] = .bool(true) }
        guard case .object(let report)? = KeybindingReports.resolve(keys, context: context, registry: tabs ? on : off, window: nil),
              report["outcome"]?.stringValue == "run", case .object(let winner)? = report["winner"] else { return (nil, nil) }
        guard case .object(let arguments)? = winner["args"] else { return (winner["command"]?.stringValue, nil) }
        return (winner["command"]?.stringValue, arguments["scope"]?.stringValue)
    }

    /// On, Cmd-Shift-] / [ go to the next and previous workspace (workspaces only) from a terminal, a page or a chat.
    @Test(arguments: ["terminal", "page", "agent"])
    func cmdShiftBracketsStepWorkspaces(_ surface: String) {
        let next = Self.winner("cmd+shift+rightbracket", in: surface, tabs: true)
        let previous = Self.winner("cmd+shift+leftbracket", in: surface, tabs: true)
        #expect(next.command == "nextSidebarTab")
        #expect(previous.command == "prevSidebarTab")
        #expect(next.scope == SidebarNavigation.workspacesScope)
        #expect(previous.scope == SidebarNavigation.workspacesScope)
    }

    /// Off (the default), the keys cycle the focused pane's tabs, as they ship.
    @Test(arguments: ["terminal", "page", "agent"])
    func offTheKeysStillCycleTabs(_ surface: String) {
        #expect(Self.winner("cmd+shift+rightbracket", in: surface, tabs: false).command == "nextSurface")
        #expect(Self.winner("cmd+shift+leftbracket", in: surface, tabs: false).command == "prevSurface")
    }

    /// Compact workspace navigation leaves the focused pane's Ctrl-Tab bindings available.
    @Test(arguments: ["terminal", "page", "agent"])
    func paneTabKeysCoexistWithCompactWorkspaces(_ surface: String) {
        #expect(Self.winner("ctrl+tab", in: surface, tabs: true).command == "nextSurface")
        #expect(Self.winner("ctrl+shift+tab", in: surface, tabs: true).command == "prevSurface")
    }

    /// Home (its top page and the docked Home) keeps whatever its Cmd-Shift-[ / ] run without the toggle.
    @Test(arguments: ["home", "home-dock"])
    func homeKeepsItsKeys(_ surface: String) {
        for keys in ["cmd+shift+rightbracket", "cmd+shift+leftbracket"] {
            #expect(Self.winner(keys, in: surface, tabs: true).command == Self.winner(keys, in: surface, tabs: false).command)
        }
    }

    static let bracketKeys = ["]", "["].map { KeybindingReports.text([Shortcut($0, modifiers: [.command, .shift])]) }

    /// The rows of the shortcut list, as Settings > Keyboard Shortcuts and `keybinding.list` show them.
    static func rows(_ registry: ActionRegistry) -> [[String: JSONValue]] {
        guard case .object(let page) = KeybindingReports.pageList([:], registry: registry),
              case .array(let rows)? = page["bindings"] else { return [] }
        return rows.compactMap { if case .object(let entry) = $0 { entry } else { nil } }
    }

    /// Off (the default, Release builds too), the shortcut list is the shipped one: no workspaces-as-tabs
    /// row, so no new conflict badge on Cmd-Shift-[ / ], whose rows list only the pane tab actions.
    /// On, the two rows appear.
    @Test func offTheShortcutListIsTheShippedOne() {
        let off = Self.rows(Self.off), on = Self.rows(Self.on)
        // Closures stay outside #expect: the fleet toolchain refuses a rethrows call inside it.
        let scoped = off.filter { $0["when"]?.stringValue?.contains(KeyContext.workspacesAsTabs) == true }
        let brackets = off.filter { Self.bracketKeys.contains($0["key"]?.stringValue ?? "") }
        let bracketCommands = Set(brackets.compactMap { $0["command"]?.stringValue })
        #expect(scoped.isEmpty, "\(scoped)")
        // The pane tab actions, and on Home the chat list's (HomeChatSwitchingKeyTests).
        #expect(bracketCommands == ["nextSurface", "prevSurface", "home.nextConversation", "home.previousConversation"], "\(bracketCommands)")
        #expect(on.count == off.count + 2)
    }

    /// The window's key context carries the toggle while it is on.
    @Test func theToggleReachesTheKeyContext() {
        var focus = FocusState()
        focus.resolved = .sidebar
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts(workspacesAsTabs: true))[KeyContext.workspacesAsTabs] == .bool(true))
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts())[KeyContext.workspacesAsTabs] == nil)
    }

    /// The default sidebar: the document's top block (Home, the App Store) as list rows, a loose
    /// workspace, a group holding one, and another loose one.
    static func order() -> (SidebarItemOrder, [CmuxNextSidebar.WorkspaceID]) {
        let ids = ["ws-1", "ws-2", "ws-3"].map { CmuxNextSidebar.WorkspaceID($0) }
        let ws = ids.enumerated().map { SidebarWorkspace(id: $1, title: "w\($0 + 1)") }
        let block = CmuxNextSidebar.SidebarSection(
            kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue, title: "", showsTitle: false)), nodes: [])
        let group = SidebarGroup(id: GroupID("grp-mid"), name: "Middle", workspaces: [ws[1]])
        let list = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                  nodes: [.workspace(ws[0]), .group(group), .workspace(ws[2])])
        return (SidebarModel(sections: [block, list]).itemOrder, ids)
    }

    /// With the default settings (every item, Home included), the toggle's keys walk only the
    /// workspaces: past the last one they wrap to the first, never to Home or the App Store, and they
    /// go through a group's workspace.
    @Test func theToggleKeysSkipTheTopItemsAndWrap() throws {
        let (order, ids) = Self.order()
        try #require(order.items.contains(.topItem(LayoutItemID("itm_home"))), "no Home in \(order.items)")
        let walk = SidebarNavigation.stepping(.defaults, scope: SidebarNavigation.workspacesScope)
        #expect(order.step(from: .workspace(ids[2]), by: 1, walk) == .workspace(ids[0]))
        #expect(order.step(from: .workspace(ids[0]), by: -1, walk) == .workspace(ids[2]))
        #expect(order.step(from: .workspace(ids[0]), by: 1, walk) == .workspace(ids[1]))
        // From Home (shown by a click), the next workspace key goes to the first workspace.
        #expect(order.step(from: .topItem(LayoutItemID("itm_home")), by: 1, walk) == .workspace(ids[0]))
        // It wraps even with `sidebar.steppingWraps` off; Ctrl-Cmd-] / [ keep the settings as they are.
        let noWrap = SidebarNavigationSettings(steppingWraps: false)
        #expect(order.step(from: .workspace(ids[2]), by: 1, SidebarNavigation.stepping(noWrap, scope: SidebarNavigation.workspacesScope)) == .workspace(ids[0]))
        #expect(SidebarNavigation.stepping(.defaults, scope: nil) == .defaults)
    }

    /// A workspace that reports a folder, a branch, two status entries and a pull request.
    static func busy() -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("ws-busy"), title: "deploy the docs", directory: "~/code/docs", branch: "main",
                                  pullRequest: "#4821", activity: .waiting)
        ws.reported = SidebarWorkspaceStatus(entries: [.init(key: "build", text: "Building"), .init(key: "tests", text: "412 passed")])
        return ws
    }

    /// On, the row is one line: the name, the status glyph (waiting: the needs-you mark) and the pull
    /// request badge; no second line, status block or third line, at either density.
    @Test(arguments: [false, true])
    func aWorkspaceRowIsOneLine(_ expanded: Bool) {
        var options = SidebarLayoutOptions()
        options.workspacesAsTabs = true
        options.expanded = expanded
        options.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: [.directory, .branch, .agentStatus]))
        // The pull request badge follows `sidebar.workspaceRow.pullRequest` here too (off by default,
        // Leo 2026-10-21: "REMOVE PR INDICATORS BY DEFAULT").
        #expect(options.rowContent(Self.busy(), machine: nil).badge == nil)
        options.workspaceRow.base.shown.insert(.pullRequest)
        let content = options.rowContent(Self.busy(), machine: nil)
        #expect(content.detail == nil)
        #expect(content.status == nil)
        #expect(content.meta == nil)
        #expect(content.trailingStatus == nil)
        #expect(content.badge == "#4821")
        #expect(content.activity == .waiting)
        #expect(SidebarLayoutMetrics.standard.height(for: content) == SidebarLayoutMetrics.standard.rowHeight)
    }

    @Test(arguments: [false, true])
    func turningCompactOffRestoresTheConfiguredRow(_ expanded: Bool) {
        var options = SidebarLayoutOptions()
        options.expanded = expanded
        options.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: [.directory, .branch, .agentStatus]))
        let original = options.rowContent(Self.busy(), machine: nil)
        #expect(original.detail != nil)
        options.workspacesAsTabs = true
        #expect(options.rowContent(Self.busy(), machine: nil).detail == nil)
        options.workspacesAsTabs = false
        #expect(options.rowContent(Self.busy(), machine: nil) == original)
    }

    @Test func compactRowsKeepTheWorkingIndicator() {
        var workspace = Self.busy()
        workspace.activity = .working
        workspace.agentWorking = true
        var options = SidebarLayoutOptions()
        options.workspacesAsTabs = true
        let content = options.rowContent(workspace, machine: nil)
        #expect(content.showsWorking)
        #expect(content.activity == .working)
        #expect(content.detail == nil)
    }

    /// Different activity states do not reorder the manually arranged workspace list.
    @Test func compactPresentationPreservesManualOrder() {
        var first = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("manual-first"), title: "Zebra")
        first.activity = .idle
        let second = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("manual-second"), title: "Alpha", activity: .waiting)
        let third = SidebarWorkspace(id: CmuxNextSidebar.WorkspaceID("manual-third"), title: "Middle", agentWorking: true)
        let group = SidebarGroup(id: GroupID("manual-group"), name: "Group", workspaces: [second])
        let section = CmuxNextSidebar.SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                                                   nodes: [.workspace(first), .group(group), .workspace(third)])
        var options = SidebarLayoutOptions()
        let original = SidebarLayout.make(sections: [section], metrics: .standard, options: options).rows.map(\.key)
        options.workspacesAsTabs = true
        let compact = SidebarLayout.make(sections: [section], metrics: .standard, options: options).rows.map(\.key)
        #expect(compact == original)
        let workspaces = compact.compactMap { key -> CmuxNextSidebar.WorkspaceID? in
            if case .workspace(let id) = key { return id }
            return nil
        }
        #expect(workspaces == [first.id, second.id, third.id])
    }
}
