import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
@testable import CmuxNextTabs
import Foundation
import Testing

/// Lawrence 2026-10-22: "can't 'x' out of subagent tab". A click on a subagent in a chat opens the
/// subagent's pane (`chat.subagentPane`, AgentSubagentPanes): a second tab on the chat's own acpmux
/// session, beside the chat. Its x must close it, as any tab's does. Runs the app's open path
/// (`AgentTabStore.openBeside`, as `openSubagent` places it) against a same-tree cmux-tui daemon,
/// then presses the x in the strip.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SubagentTabCloseTests {
    static let session = "chat-subagent-tab-close"

    @Test(arguments: [MainPaneOverride.on, .off])
    func aSubagentTabClosesWithItsX(_ layout: MainPaneOverride) async throws {
        TunableStore.shared.set(MainPaneLayout.debugOverride.key, layout.tunableValue)
        defer { TunableStore.shared.set(MainPaneLayout.debugOverride.key, nil) }
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let tabs = services.agentTabs
            tabs.localHost = AgentSessionRef.host(installID: "cn-subagent-tab-close")
            let model = try #require(store.workspaces.first?.screens.first?.panes.first)
            let first = try #require(model.tabs.first?.surface)

            // The chat, alone in its pane.
            let record = AgentSessionRef(host: try #require(tabs.localHost), hostName: "This Mac", session: Self.session, harness: "claude")
            let chat = try await connection.request(NewConversationTabRequest(agentSession: record, pane: model.handle))
            try await connection.closeTab(first)
            try await PinnedPageTests.until({ store.tab(surface: chat.surface) != nil && store.tab(surface: first) == nil })
            let chatID = try #require(store.tab(surface: chat.surface)).id

            // The subagent's pane, opened as a click on its row opens it.
            var created: String?
            var moved: Bool?
            let opened = tabs.openBeside(chatID, direction: "right", origin: .user, main: chatID, open: { pane, daemon in
                try tabs.open(in: pane, of: daemon, session: Self.session)
            }, created: { created = $0 }, finished: { moved = $0 })
            try #require(opened, "the subagent pane did not open")
            try await PinnedPageTests.until({ moved != nil }, within: .seconds(30), report: { Self.describe(services) })
            let key = try #require(created.map(tabs.resolve))
            let (_, pane) = try #require(services.locateTab(key), "the subagent tab is gone: \(Self.describe(services))")
            let controller = try #require(services.paneController(for: pane), "no pane shows the subagent tab: \(Self.describe(services))")
            try await PinnedPageTests.until({ controller.stripModel.tab(StripTabID(key)) != nil }, report: { Self.describe(services) })
            #expect(controller.stripModel.tab(StripTabID(key))?.isClosable == true, "the subagent tab has no x: \(Self.describe(services))")

            // Its x: the tab goes, and stays gone.
            controller.view.stripView.close(StripTabID(key), source: .mouse)
            try await PinnedPageTests.until({ services.locateTab(key) == nil }, within: .seconds(10),
                                            report: { "the x left the subagent tab open: " + Self.describe(services) })
            try await Task.sleep(for: .seconds(2))
            #expect(services.locateTab(key) == nil, "the subagent tab came back: \(Self.describe(services))")
            #expect(store.tab(id: chatID) != nil, "the x closed the chat")
        }
    }

    private static func describe(_ services: AppServices) -> String {
        guard let content = services.windows.active?.workspaceContent else { return "no workspace" }
        let screens = content.workspace.screens.map { screen in
            let columns = screen.columns.map { "\($0.layout.paneIDs.map(\.rawValue))\($0.dock.map { " dock(\($0.edge),pinned:\($0.isPinned))" } ?? "")" }
            let panes = screen.panes.map { pane in
                let strip = services.paneController(for: pane).map { " strip \($0.stripModel.orderedTabs.map { "\($0.id.rawValue)\($0.isClosable ? "" : "(no x)")" })" } ?? " (no controller)"
                return "pane \(pane.handle.rawValue): \(pane.tabs.map { "\($0.id)\($0.agentSession == nil ? "" : "[chat]")" })\(strip)"
            }
            return "columns \(columns); " + panes.joined(separator: "; ")
        }
        return screens.joined(separator: " | ")
    }
}
