import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Switch to Chat / Switch to Terminal on a terminal and chat pair (user 2026-11-20: "we used to have an additional
/// button that will let u switch from terminal to chat ui"). The toolbar's `>_ | bubble` control (#42748) went on
/// 2026-11-13 (821f04425f5a), and the pane's "…" that offered it after went with
/// https://github.com/manaflow-ai/cmux/issues/53356; its action, Toggle Terminal and Chat (`palette.toggleTerminalChat`),
/// stays in the palette and leads the tab's right-click, titled by the way it goes.
@MainActor @Suite(.serialized)
struct TerminalChatSwitchMenuTests {
    static let toggle: ActionID = "palette.toggleTerminalChat"

    /// One workspace whose pane holds terminal `term` (surface 1), in a pane controller with no window.
    @MainActor struct Fixture {
        let services: AppServices
        let pane: PaneController
        let terminal: TabModel

        init() throws {
            services = IncognitoSurfacesTests.services()
            AppActions.bind(services)
            let paneSnapshot = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "claude")])
            let workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey.generate(), name: "work",
                                              screens: [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(paneSnapshot.id), panes: [paneSnapshot])])
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [workspace]))
            let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            terminal = try #require(model.tabs.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
            pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: WindowState(record: record))
        }

        /// The terminal runs a Claude Code session (its hooks reported it).
        func runAgent() {
            terminal.agent = AgentStatus(surface: SurfaceID(rawValue: 1), state: .idle, session: "s-1", agent: "claude")
        }

        /// The terminal tab's right-click, every row (submenus too). The pane's "…" that also led with the switch is
        /// gone (#53356); the right-click keeps it.
        func rightClickMenu() throws -> [NSMenuItem] {
            let id = StripTabID(terminal.id)
            let menu = try #require(pane.contextMenu(for: .tab(id, selection: [id])))
            func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(all) }
            return all(menu)
        }
    }

    @Test func aTerminalRunningAnAgentOffersSwitchToChatFirstInItsRightClick() throws {
        let fixture = try Fixture()
        fixture.runAgent()
        let rows = try fixture.rightClickMenu()
        let row = try #require(rows.first { ActionRegistry.menuRun(of: $0)?.id == Self.toggle }, "the right-click offers no switch")
        #expect(row.title == "Switch to Chat")
        #expect(rows.first === row, "the tab's own switch leads its right-click")
        #expect(rows.dropFirst().first?.isSeparatorItem == true)
        #expect(ActionRegistry.menuRun(of: row)?.target == ActionTargetRef(kind: .tab, id: fixture.terminal.id))
    }

    @Test func aPlainTerminalOffersNoSwitch() throws {
        let fixture = try Fixture()
        let rows = try fixture.rightClickMenu()
        #expect(!rows.contains { ActionRegistry.menuRun(of: $0)?.id == Self.toggle }, "a shell with no agent session has no chat")
    }

    // The title the palette and both menus read: only a terminal running a session the toggle can open as a chat
    // reads Switch to Chat; a plain shell or an agent it cannot open keeps the catalog's title (no promise it breaks).
    @Test(arguments: [("claude", "Switch to Chat"), ("codex", "Switch to Chat"), ("opencode", nil)] as [(String, String?)])
    func aTerminalsTitleNamesTheWayItGoes(agent: String, title: String?) throws {
        let fixture = try Fixture()
        #expect(TerminalChatHandler.switchTitle(of: fixture.terminal, services: fixture.services) == nil)
        fixture.terminal.agent = AgentStatus(surface: SurfaceID(rawValue: 1), state: .idle, session: "s-1", agent: agent)
        #expect(TerminalChatHandler.switchTitle(of: fixture.terminal, services: fixture.services) == title)
    }

    // The right-click's row is the same row, titled the same way (one path: the action's target title).
    @Test func theRightClickNamesTheDirectionToo() throws {
        let fixture = try Fixture()
        fixture.runAgent()
        let id = StripTabID(fixture.terminal.id)
        let menu = try #require(fixture.pane.contextMenu(for: .tab(id, selection: [id])))
        let row = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == Self.toggle })
        #expect(row.title == "Switch to Chat")
    }
}
