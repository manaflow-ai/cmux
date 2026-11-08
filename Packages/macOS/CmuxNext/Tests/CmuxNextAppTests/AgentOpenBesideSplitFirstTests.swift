import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-11-05: "things just don't open up fast enough on the right. / links. subagents. all". A subagent,
/// side chat or fork opened on a chat's right was made as a tab in the chat's own pane, waited for the
/// store to list it, and was then moved to a new split (`tab.moveToNewSplit`): two daemon round trips
/// before the split showed, with the tab in the chat's strip meanwhile. With `conversation-tab-split-v1` it
/// is made in its new split by one `new-conversation-tab {split}`, as a link's browser tab is
/// (LinkOpenSplitDirectTests): the split shows at once with the chat's stand-in, the chat's pane never
/// lists it, and nothing moves.
@MainActor @Suite(.serialized) struct AgentOpenBesideSplitFirstTests {
    /// What the faked `new-conversation-tab` was asked.
    @MainActor private final class Creates {
        var splits: [ConversationTabSplit?] = []
        let (heard, hear) = AsyncStream<Void>.makeStream()
    }

    private static let host = "install:split-first-test"

    /// One chat tab alone on its screen, on a daemon advertising `capabilities`; agent tab creates are faked
    /// (they record their `split` and refuse).
    private static func chat(capabilities: [DaemonCapability]) throws -> (AppServices, AgentTabStore, String, Creates) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let list = capabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"split-first","generation":"g1","capabilities":["# + list + "]}"
        store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: "s-chat", harness: "codex"))
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [chat])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let key = try #require(store.pane(PaneID(rawValue: 1))?.tabs.first?.id)
        let tabs = services.agentTabs
        tabs.localHost = host
        tabs.holdsTabs = { _ in true }
        tabs.reachable = { _ in true }
        tabs.locate = { [weak services] _ in services.map { (pane: PaneID(rawValue: 1), daemon: $0.daemon) } }
        // Nothing on the chat's right, and the chat is wide enough to halve: a split right.
        tabs.rightColumn = { _ in .init(sourceWidth: 1400) }
        tabs.serially = { _, turn in turn({}); return true }
        tabs.openInMainPane = { _, _, _, _, _ in nil }
        let creates = Creates()
        tabs.create = { _, _, _, _, _, split in
            creates.splits.append(split)
            creates.hear.yield()
            throw CancellationError()
        }
        return (services, tabs, key, creates)
    }

    private static let served: [DaemonCapability] = [.agentSessionTabs, .conversationTabSplit, .splitClientKeys, .splitClientSplitID]

    /// A fork to the right (the chat's Fork to Right Split): made in its split, one create, never in the chat's pane.
    @Test(.timeLimit(.minutes(1))) func aForkToTheRightIsMadeInItsSplitNeverInTheChat() async throws {
        let (services, tabs, chat, creates) = try Self.chat(capabilities: Self.served)
        let store = services.daemon.store

        #expect(tabs.openFork("s-fork", at: .right, beside: chat))

        // The split shows now, before any reply: its provisional pane holds the fork's stand-in tab.
        let intent = try #require(store.pendingIntents.first)
        guard case .splitPane(let target, let direction, _, let provisional) = intent else {
            Issue.record("the fork did not open as a split intent: \(intent)")
            return
        }
        #expect(target == PaneID(rawValue: 1))
        #expect(direction == .right)
        #expect(provisional.tab?.kind == .conversation)
        #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)], "the fork's tab showed in the chat's pane")

        if creates.splits.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.splits.count == 1, "one new-conversation-tab, not a create and a move")
        #expect(creates.splits[0]?.direction == .right)
        #expect(creates.splits[0]?.paneID == provisional.paneID)
    }

    /// A subagent opened from its chat (`chat.subagentPane`) beside an empty right column: one create in its split.
    @Test(.timeLimit(.minutes(1))) func aSubagentOnTheRightIsMadeInItsSplit() async throws {
        let (services, tabs, chat, creates) = try Self.chat(capabilities: Self.served)
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-chat")
        tabs.wireHeader(model, key: chat)
        let header = try #require(model.header)

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "reviewer", true))

        #expect(services.daemon.store.pendingIntents.contains { if case .splitPane = $0 { true } else { false } },
                "the subagent's split did not show at once")
        if creates.splits.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.splits.count == 1)
        #expect(creates.splits[0]?.direction == .right, "the subagent was made in the chat's pane, to be moved")
        withExtendedLifetime(model) {}
    }

    /// #36226 review: the subagent's tab decides at its first show (`view(for:)`) whether it takes the warm spare, from
    /// its reveal (`pendingTurns`). The split, and its provisional tab, show as the open returns, before the store has
    /// answered the create; the reveal recorded only once it answered (`created`) could come after that first show, and
    /// the pane then opened cold. Here the create never answers: the reveal is on the provisional tab all the same.
    @Test(.timeLimit(.minutes(1))) func aSubagentsRevealIsOnItsTabBeforeTheStoreAnswers() async throws {
        let (services, tabs, chat, creates) = try Self.chat(capabilities: Self.served)
        let model = AgentPaneModel(host: NoHost(), sessionId: "s-chat")
        tabs.wireHeader(model, key: chat)
        let header = try #require(model.header)

        #expect(header.openSubagent("s-chat-\(UUID().uuidString.prefix(8))", "reviewer", true))

        #expect(services.daemon.store.pendingIntents.contains { if case .splitPane = $0 { true } else { false } })
        #expect(tabs.pendingTurns.values.contains(AgentSubagentPanes.reveal("reviewer")),
                "the provisional tab can show (view(for:)) with no reveal, so it opens cold: \(tabs.pendingTurns)")
        if creates.splits.isEmpty { for await _ in creates.heard { break } }
        withExtendedLifetime(model) {}
    }

    /// An older daemon (no `conversation-tab-split-v1`) keeps the make-and-move path: no `split`, which it would ignore.
    @Test(.timeLimit(.minutes(1))) func withoutTheCapabilityTheTabIsMadeInTheChatsPane() async throws {
        let (services, tabs, chat, creates) = try Self.chat(capabilities: [.agentSessionTabs, .splitClientKeys])
        #expect(tabs.openFork("s-fork-old", at: .right, beside: chat))
        #expect(!services.daemon.store.pendingIntents.contains { if case .splitPane = $0 { true } else { false } })
        if creates.splits.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.splits.count == 1)
        #expect(creates.splits[0] == nil)
    }

    @Test func onlyRightAndDownAreMadeInTheirSplit() {
        #expect(SplitDirection(splitFirst: "right", served: true) == .right)
        #expect(SplitDirection(splitFirst: "down", served: true) == .down)
        #expect(SplitDirection(splitFirst: "left", served: true) == nil)
        #expect(SplitDirection(splitFirst: "up", served: true) == nil)
        #expect(SplitDirection(splitFirst: "right", served: false) == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
