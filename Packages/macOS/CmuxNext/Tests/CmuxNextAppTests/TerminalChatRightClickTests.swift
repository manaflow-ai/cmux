import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextWindowRules
import Foundation
import Testing

/// Toggle Terminal and Chat without the pane toolbar's `>_ | bubble` control (user 2026-11-13: "get rid of these
/// buttons"): its key (Opt-Cmd-`), the Command Palette, and a row of the tab's right-click on half of a terminal and
/// chat pair, which runs `palette.toggleTerminalChat` on that tab through the registry, one path with the key.
@MainActor @Suite(.serialized)
struct TerminalChatRightClickTests {
    static let toggle: ActionID = "palette.toggleTerminalChat"

    // Pair membership is the Rust route's answer (cmux-window-rules `tabs::terminal_chat_toggle`) for the facts the
    // action builds: a refusal offers no row.
    @Test func theRowIsOfferedOnlyOnAPair() {
        let rules = WindowRules()
        let offered = { (facts: WindowRules.ToggleFacts) in TerminalChatHandler.offersToggle(rules.terminalChatToggle(facts)) }
        // A terminal running a Claude Code session, and the chat resuming one a terminal runs: a pair.
        #expect(offered(.init(terminal: true, agent: "claude", session: "s-1")))
        #expect(offered(.init(chat: true, agent: "codex", session: "s-2", running: true)))
        // A chat whose terminal is gone is still one half: the row resumes the session in a terminal.
        #expect(offered(.init(chat: true, agent: "codex", session: "s-2")))
        #expect(offered(.init(chat: true, agent: "codex", session: "s-2", busy: true)))
        // A plain terminal, a cmux chat with no outside session, an agent acpmux cannot resume: none.
        #expect(!offered(.init(terminal: true, agent: nil, session: nil)))
        #expect(!offered(.init(chat: true, agent: nil, session: nil)))
        #expect(!offered(.init(terminal: true, agent: "opencode", session: "x")))
        #expect(!offered(.init(agent: "claude", session: "s")))
    }

    @Test func aPlainTerminalTabIsOfferedNoRow() {
        let services = TerminalChatTests.services()
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 1)))
        #expect(!TerminalChatHandler.offersToggle(on: tab, services: services))
        tab.agent = AgentStatus(surface: SurfaceID(rawValue: 1), state: .idle, session: "s-1", agent: "claude")
        #expect(TerminalChatHandler.offersToggle(on: tab, services: services))
    }

    @Test func theRowRunsTheToggleOnTheRightClickedTab() throws {
        _ = NSApplication.shared
        let registry = ActionRegistry(catalog: [.init(id: Self.toggle, title: "Toggle Terminal and Chat", category: .other)])
        var runs: [ActionInvocation] = []
        registry.bind(Self.toggle, invoke: { runs.append($0) })
        let rows = PaneController.terminalChatRows(tab: "term", registry: registry, machineID: nil)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "Toggle Terminal and Chat")
        #expect(ActionRegistry.menuRun(of: row)?.id == Self.toggle)
        #expect(NSApplication.shared.sendAction(try #require(row.action), to: row.target, from: row))
        #expect(runs.first?.target == ActionTargetRef(kind: .tab, id: "term"))
    }

    // The row leads the tab's menu, above a separator; a tab with nothing of its own keeps its menu as it was.
    @Test func ownRowsLeadTheTabsMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Duplicate Tab", action: nil, keyEquivalent: "")
        PaneController.prepend([], to: menu)
        #expect(menu.items.map(\.title) == ["Duplicate Tab"])
        PaneController.prepend([NSMenuItem(title: "Toggle Terminal and Chat", action: nil, keyEquivalent: "")], to: menu)
        #expect(menu.items.map(\.title) == ["Toggle Terminal and Chat", "", "Duplicate Tab"])
        #expect(menu.items[1].isSeparatorItem)
    }
}
