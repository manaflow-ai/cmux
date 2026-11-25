import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-05: "things just don't open up fast enough on the right. / links. subagents. all". Once the chat's
/// right column holds two panes (or the chat is too narrow to split), a subagent opens as a tab in the column's
/// lower pane (`RightColumnPlacement` `.tab`). Its provisional tab joined that pane's strip at once, but the pane
/// kept showing what it showed until the store answered the create and listed the tab, and only then `tab.focus`
/// (or, unfocused, `selectInPaneScoped`) selected it: a daemon round trip before anything changed on the right.
/// It is selected in the click's turn now (`selectInPaneScoped`, which finds the provisional tab in the store), as a
/// link's stand-in tab is (`PaneBrowserTabOpener.openStandIn`), with the focus expected on it for a click (`showSplitScoped`).
@MainActor @Suite(.serialized) struct AgentOpenInRightPaneNowTests {
    /// The tabs selected in their pane (`selectInPaneScoped`) and those whose focus was expected (`showSplitScoped`).
    @MainActor private final class Shown {
        var selected: [String] = []
        var focused: [String] = []
    }

    private static let host = "install:right-pane-now-test"

    /// One chat tab with a right column of `column`; agent tab creates are faked (they never answer).
    private static func chat(column right: RightColumnPlacement.Column) throws -> (AppServices, AgentTabStore, String, Shown) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let capabilities = [DaemonCapability.agentSessionTabs, .conversationTabSplit, .splitClientKeys, .splitClientSplitID]
        let list = capabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"right-pane-now","generation":"g1","capabilities":["# + list + "]}"
        store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-chat", harness: "codex"))
        let panes = [PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat]),
                     PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), kind: .browser, cwd: nil)]),
                     PaneSnapshot(id: PaneID(rawValue: 3), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 3), kind: .browser, cwd: nil)])]
        let column = LayoutNode.split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(PaneID(rawValue: 2)), b: .leaf(PaneID(rawValue: 3)))
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(PaneID(rawValue: 1)), b: column)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let key = try #require(store.pane(PaneID(rawValue: 1))?.tabs.first?.id)
        let tabs = services.agentTabs
        tabs.localHost = host
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.locateScoped = { [weak services] _ in services.map { (pane: PaneID(rawValue: 1), daemon: $0.daemon) } }
        tabs.locatePaneScoped = { [weak services] _, key in
            services.map { (pane: PaneID(rawValue: key == "lower" ? 3 : 2), daemon: $0.daemon) }
        }
        tabs.rightColumnScoped = { _ in right }
        tabs.seriallyScoped = { _, turn in turn({}); return true }
        tabs.openInMainPaneScoped = { _, _, _, _, _ in nil }
        tabs.create = { _, _, _, _, _, _ in try await Task.sleep(for: .seconds(60)); throw CancellationError() }
        let shown = Shown()
        tabs.selectInPaneScoped = { key in shown.selected.append(key.key) }
        tabs.showSplitScoped = { _, key, focus in
            if focus { shown.focused.append(key) }
            return { _ in }
        }
        return (services, tabs, key, shown)
    }

    /// The id of the provisional tab the open put on the store in pane `pane`, as the store lists it.
    private static func provisional(in store: DaemonStore, pane: PaneID) -> String? {
        store.pendingIntents.lazy.compactMap { intent -> String? in
            guard case .createTab(let target, let tab) = intent, target == pane else { return nil }
            return store.tabsBySurface[tab.surface]?.id
        }.first
    }

    private static let twoPanes = RightColumnPlacement.Column(sourceWidth: 1400, panes: ["upper", "lower"])

    /// A person's click on a subagent while the right column holds two panes: its tab shows in the lower pane, focused, now.
    @Test(.timeLimit(.minutes(1))) func aClickedSubagentShowsInTheColumnsLowerPaneNow() throws {
        let (services, tabs, chat, shown) = try Self.chat(column: Self.twoPanes)
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-chat")
        tabs.wireHeader(model, key: chat)
        let header = try #require(model.header)

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "reviewer", true))

        let tab = try #require(Self.provisional(in: services.daemon.store, pane: PaneID(rawValue: 3)),
                               "the subagent's tab was not made in the column's lower pane: \(services.daemon.store.pendingIntents)")
        #expect(shown.selected == [tab], "the lower pane kept showing what it showed until the store answered the create")
        #expect(shown.focused == [tab])
        withExtendedLifetime(model) {}
    }

    /// An open nobody asked for (the summary card's switch): shown in the lower pane now, and the chat keeps the focus.
    @Test(.timeLimit(.minutes(1))) func anUnfocusedSubagentShowsThereWithoutTheFocus() throws {
        let (services, tabs, chat, shown) = try Self.chat(column: Self.twoPanes)
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-chat")
        tabs.wireHeader(model, key: chat)
        let header = try #require(model.header)

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "reviewer", false))

        let tab = try #require(Self.provisional(in: services.daemon.store, pane: PaneID(rawValue: 3)))
        #expect(shown.selected == [tab])
        #expect(shown.focused.isEmpty, "an open nobody asked for took the focus")
        withExtendedLifetime(model) {}
    }

    /// A chat too narrow to split opens the subagent as a tab in its own pane: a click shows it there now, but an open
    /// nobody asked for never replaces the chat the person is reading.
    @Test(.timeLimit(.minutes(1))) func inTheChatsOwnPaneOnlyAClickShowsIt() throws {
        let narrow = RightColumnPlacement.Column(sourceWidth: 300)
        let (services, tabs, chat, shown) = try Self.chat(column: narrow)
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-chat")
        tabs.wireHeader(model, key: chat)
        let header = try #require(model.header)

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "quiet", false))
        #expect(shown.selected.isEmpty, "an unasked open replaced the chat in its own pane: \(shown.selected)")

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "asked", true))
        let made = services.daemon.store.pendingIntents.compactMap { intent -> String? in
            guard case .createTab(_, let tab) = intent else { return nil }
            return services.daemon.store.tabsBySurface[tab.surface]?.id
        }
        try #require(made.count == 2, "both opens make a tab in the chat's pane: \(services.daemon.store.pendingIntents)")
        #expect(shown.selected == [made[1]])
        #expect(shown.focused == [made[1]])
        withExtendedLifetime(model) {}
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
