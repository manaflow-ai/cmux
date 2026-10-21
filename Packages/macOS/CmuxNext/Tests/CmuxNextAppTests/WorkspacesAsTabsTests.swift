import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocus
@testable import CmuxNextSidebar
import Foundation
import Testing

/// "Workspaces as tabs" (Leo, relayed 2026-10-21; `sidebar.workspacesAsTabs`, a Debug tunable,
/// off): "a Claude-desktop-style compact list (one line per workspace, title + status/PR badge +
/// needs-you icon; no second line). ⌘⇧[ and ⌘⇧] move to the previous/next workspace in sidebar
/// order, wrapping, across groups, like switching tabs." Off, nothing changes: Cmd-Shift-[ / ]
/// cycle the focused pane's tabs (Lawrence 2026-10-15), and Home keeps its keys either way.
@MainActor @Suite struct WorkspacesAsTabsTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["nextSurface", "prevSurface", "nextSidebarTab", "prevSidebarTab"] {
            registry.bind(id, invoke: { _ in })
        }
        return registry
    }()

    static func winner(_ keys: String, in surface: String, tabs: Bool) -> String? {
        var context = KeyContext([KeyContext.surfaceKind: .string(surface)])
        if tabs { context[KeyContext.workspacesAsTabs] = .bool(true) }
        guard case .object(let report)? = KeybindingReports.resolve(keys, context: context, registry: registry, window: nil),
              report["outcome"]?.stringValue == "run", case .object(let winner)? = report["winner"] else { return nil }
        return winner["command"]?.stringValue
    }

    /// On, Cmd-Shift-] / [ go to the next and previous workspace from a terminal, a page or a chat.
    @Test(arguments: ["terminal", "page", "agent"])
    func cmdShiftBracketsStepWorkspaces(_ surface: String) {
        #expect(Self.winner("cmd+shift+rightbracket", in: surface, tabs: true) == "nextSidebarTab")
        #expect(Self.winner("cmd+shift+leftbracket", in: surface, tabs: true) == "prevSidebarTab")
    }

    /// Off (the default), the keys cycle the focused pane's tabs, as they ship.
    @Test(arguments: ["terminal", "page", "agent"])
    func offTheKeysStillCycleTabs(_ surface: String) {
        #expect(Self.winner("cmd+shift+rightbracket", in: surface, tabs: false) == "nextSurface")
        #expect(Self.winner("cmd+shift+leftbracket", in: surface, tabs: false) == "prevSurface")
    }

    /// Home (its top page and the docked Home) keeps whatever its Cmd-Shift-[ / ] run without the toggle.
    @Test(arguments: ["home", "home-dock"])
    func homeKeepsItsKeys(_ surface: String) {
        for keys in ["cmd+shift+rightbracket", "cmd+shift+leftbracket"] {
            #expect(Self.winner(keys, in: surface, tabs: true) == Self.winner(keys, in: surface, tabs: false))
        }
    }

    /// The default keymap is the same with the prototype off: no default Cmd-Shift-[ / ] entry is unscoped.
    @Test func theShippedKeymapDoesNotChange() {
        let workspaceKeys = KeyBindingDefaults.tabSwitching.filter { $0.command.rawValue.hasSuffix("SidebarTab") && $0.keys.first?.modifiers == [.command, .shift] }
        #expect(workspaceKeys.isEmpty)
        for binding in KeyBindingDefaults.workspacesAsTabs {
            #expect(binding.when?.evaluate(KeyContext([KeyContext.surfaceKind: .string("terminal")])) == false)
        }
    }

    /// The window's key context carries the toggle while it is on.
    @Test func theToggleReachesTheKeyContext() {
        var focus = FocusState()
        focus.resolved = .sidebar
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts(workspacesAsTabs: true))[KeyContext.workspacesAsTabs] == .bool(true))
        #expect(KeyRouter.keyContext(for: focus, appContext: [], facts: KeyFacts())[KeyContext.workspacesAsTabs] == nil)
    }

    /// Stepping walks the rows in sidebar order across groups and wraps at both ends.
    @Test func steppingWrapsAcrossGroups() {
        let (a, b, c) = (CmuxNextSidebar.WorkspaceID("ws-a"), CmuxNextSidebar.WorkspaceID("ws-b"), CmuxNextSidebar.WorkspaceID("ws-c"))
        let order = SidebarItemOrder(topItems: [], rows: [.workspace(a), .workspace(b), .workspace(c)])
        let settings = SidebarNavigationSettings(stepping: .workspacesOnly)
        #expect(order.step(from: .workspace(c), by: 1, settings) == .workspace(a))
        #expect(order.step(from: .workspace(a), by: -1, settings) == .workspace(c))
        #expect(order.step(from: .workspace(a), by: 1, settings) == .workspace(b))
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
        let content = options.rowContent(Self.busy(), machine: nil)
        #expect(content.detail == nil)
        #expect(content.status == nil)
        #expect(content.meta == nil)
        #expect(content.trailingStatus == nil)
        #expect(content.badge == "#4821")
        #expect(content.activity == .waiting)
        #expect(SidebarLayoutMetrics.standard.height(for: content) == SidebarLayoutMetrics.standard.rowHeight)
    }
}
