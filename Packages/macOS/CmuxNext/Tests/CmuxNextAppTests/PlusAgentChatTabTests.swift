import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// User 2026-11-12: "if i use plus button to open agent chat it should open it as a tab, not like a docked
/// one to left". The tab bar's + (its menu's New Agent Chat, Option-click's New Agent Chat Tab) opens the
/// chat as a tab in that pane, selected, like every other tab it opens. Cmd-I names no pane and keeps the
/// left chat dock (DockedAgentChat).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct PlusAgentChatTabTests {
    /// The + menu's New Agent Chat, run through the menu item itself: a tab in the + 's pane, selected, no dock.
    @Test func thePlusMenuOpensTheChatAsATabInItsPane() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try await Self.terminalPane(services, install: "plus-agent-tab-menu")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            let menu = services.registry.makePaneCreationMenu(target: ActionTargetRef(kind: .pane, id: controller.paneKey),
                                                              machineID: controller.daemon.machineID)
            let row = try #require(menu.items.firstIndex { ActionRegistry.menuRun(of: $0)?.id == "palette.newAgentChat" },
                                   "the + menu lists New Agent Chat")
            menu.performActionForItem(at: row)
            try await Self.untilChatLands(after: before, services) { chat, shown in
                shown.pane === controller && !shown.docked && controller.stripModel.selectedID?.rawValue == chat
            }
        }
    }

    /// Option-click on the + over a chat (New Agent Chat Tab, `newTab.ofKind`): another chat tab in the pane.
    @Test func optionClickOnThePlusOpensAnotherChatTabInItsPane() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try await Self.terminalPane(services, install: "plus-agent-tab-option")
            // A chat tab beside the terminal, selected, so the +'s same kind is a chat.
            var before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            #expect(controller.openAgentTab(placed: false))
            try await Self.untilChatLands(after: before, services) { chat, shown in
                shown.pane === controller && controller.stripModel.selectedID?.rawValue == chat
            }
            before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            StripNewTab.request(pane: controller.paneKey, machineID: controller.daemon.machineID, sameKind: true) {
                _ = services.registry.perform($0, invocation: $1)
            }
            try await Self.untilChatLands(after: before, services) { chat, shown in
                shown.pane === controller && !shown.docked && controller.stripModel.selectedID?.rawValue == chat
            }
        }
    }

    /// Cmd-I (a person's New Agent Chat naming no pane) still opens the chat docked left.
    @Test func cmdIStillDocksTheChatLeft() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let controller = try await Self.terminalPane(services, install: "plus-agent-tab-cmdi")
            let before = Set(PasswordManagerRouteTests.tabs(services).map(\.id))
            #expect(services.registry.perform("palette.newAgentChat", invocation: ActionInvocation(origin: .user)))
            try await Self.untilChatLands(after: before, services) { _, shown in shown.docked && shown.pane !== controller }
        }
    }

    /// The window's focused pane, a terminal whose New Agent Chat would make a new left chat dock.
    private static func terminalPane(_ services: AppServices, install: String) async throws -> PaneController {
        services.agentTabs.localHost = AgentSessionRef.host(installID: install)
        try #require(services.agentTabs.canHostChat, "this build has no agent page")
        let window = try #require(services.windows.active)
        try await PasswordManagerRouteTests.until { window.focusedPane?.stripModel.selectedID != nil }
        let controller = try #require(window.focusedPane)
        try #require(controller.daemon.supports(DaemonCapability.dockColumnRole.rawValue), "the daemon makes chat docks")
        #expect(NewChatPlacement.resolve(from: controller) == .newDock, "a terminal pane's untargeted New Agent Chat docks")
        return controller
    }

    /// The pane that shows tab `id` (not one it waits in, hidden, for its dock) and whether that pane is in a chat dock.
    private static func shown(_ id: String, _ services: AppServices) -> (pane: PaneController, docked: Bool)? {
        guard let (_, model) = services.locateTab(id),
              let pane = services.paneController(for: model), !pane.dockBound.contains(id),
              let screen = pane.workspace?.layoutModel.screen(containing: pane.layoutPaneID) else { return nil }
        let column = ChatColumnPlacement.columns(of: screen, containing: pane.layoutPaneID).first { $0.root.contains(pane.layoutPaneID) }
        return (pane, column?.dock?.role == .agentChat)
    }

    /// Waits until a chat made after `before` shows where `lands` says.
    private static func untilChatLands(after before: Set<String>, _ services: AppServices,
                                       where lands: (String, (pane: PaneController, docked: Bool)) -> Bool,
                                       sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var last = "no new chat"
        try await PasswordManagerRouteTests.until({
            guard let chat = PasswordManagerRouteTests.tabs(services).first(where: { !before.contains($0.id) && $0.agentSession != nil }) else { return false }
            guard let shown = shown(chat.id, services) else { last = "chat \(chat.id) is not shown yet"; return false }
            last = "chat \(chat.id) in pane \(shown.pane.paneKey), docked \(shown.docked), selected \(String(describing: shown.pane.stripModel.selectedID))"
            return lands(chat.id, shown)
        }, within: .seconds(30), report: { last }, sourceLocation: sourceLocation)
    }
}
