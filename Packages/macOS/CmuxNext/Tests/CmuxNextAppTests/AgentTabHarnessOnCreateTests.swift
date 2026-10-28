import CmuxAgentBrands
@testable import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-w4bbw: an agent chat tab records the harness its session runs, so the tab bar draws the
/// agent's brand mark instead of the generic chat glyph, for every way a chat opens: New Agent
/// Chat and the New Tab page (a tab with no session that its first send binds), and Open Chat (a
/// tab created with its session). The harness is the one acpmux reports in its own reply to the
/// pane (`session/new`, `_acpmux/attach`), read at the pane's frame boundary, and it reaches the
/// store with the session's bind (`bind-conversation-tab-session` `harness`).
@MainActor
struct AgentTabHarnessOnCreateTests {
    private static let host = "install:this-mac"

    /// One bind the tab store sent (`AgentTabStore.bind`).
    private struct Bind: Equatable {
        var expected: String?
        var session: String
        var harness: String?
    }

    private static func agentTabs(defaults: UserDefaults = UserDefaults()) -> AgentTabStore {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: environment, showcase: true,
                                  defaults: defaults)
        tabs.localHost = host
        return tabs
    }

    /// One pane holding an agent tab of this Mac with `session` (nil: a new chat) and no harness.
    private static func store(session: String?) -> DaemonStore {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        store.connectionState = .connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "agent-link-test")))
        return store
    }

    private static func wired(_ tabs: AgentTabStore, _ store: DaemonStore, binds: @escaping (Bind) -> Void) {
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        tabs.firstPageNewTab = { _, _ in
            (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        }
        tabs.bind = { _, _, expected, session, harness in
            binds(Bind(expected: expected, session: session, harness: harness))
            return (.taken, nil)
        }
    }

    /// The tab bar icon of the store's tab, as the strip draws it (TabItemMapping).
    private static func icon(_ store: DaemonStore) -> TabIcon? {
        store.tab(surface: 1).map { TabItemMapping.shared.item($0, fallbackTitle: "Agent").icon }
    }

    private static func mark(_ harness: String) -> TabIcon? {
        AgentBrandCatalog.brand(for: harness).map { TabIcon.agentMark($0.rawValue) }
    }

    /// acpmux's `session/new` reply, as the pane's socket reads it before the page does.
    private static func newReply(_ session: String, harness: String) -> [String: Any] {
        ["result": ["sessionId": session, "_meta": ["acpmux": ["harness": harness, "family": harness, "cwd": "/tmp"]]]]
    }

    /// acpmux's `_acpmux/attach` reply.
    private static func attachReply(_ session: String, harness: String) -> [String: Any] {
        ["result": ["session": ["sessionId": session, "harness": harness, "cwd": "/tmp"]]]
    }

    private static func persist(_ session: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": session]])
    }

    /// Waits (bounded) for the main-actor hop of a harness the pane's socket read.
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    /// New Agent Chat and the New Tab page: the tab has no session and draws the chat glyph; the
    /// first send starts a session whose harness acpmux names, and the bind records it.
    @Test func aNewChatRecordsTheHarnessItsFirstSendStarts() async throws {
        let store = Self.store(session: nil)
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        var binds: [Bind] = []
        Self.wired(tabs, store) { binds.append($0) }
        let key = try #require(store.tab(surface: 1)?.id)
        let view = try #require(tabs.view(for: key))
        #expect(Self.icon(store) != Self.mark("codex"))

        view.model.transport.sessions.observeFolder(Self.newReply("s-new", harness: "codex"), replyTo: "session/new")
        _ = await view.model.respond(to: Self.persist("s-new"))
        await Self.settle { !binds.isEmpty }
        #expect(binds.first == Bind(expected: nil, session: "s-new", harness: "codex"), "\(binds)")
        #expect(store.tab(surface: 1)?.agentSession?.harness == "codex")
        #expect(Self.icon(store) == Self.mark("codex"), "the tab does not draw the Codex mark")

        // A switch to another agent (a handoff makes a new session): its attach names the new
        // harness, and the tab's mark follows.
        _ = await view.model.respond(to: Self.persist("s-handoff"))
        await Self.settle { binds.count > 1 }
        view.model.transport.sessions.observeFolder(Self.attachReply("s-handoff", harness: "providers/claude"), replyTo: "_acpmux/attach")
        await Self.settle { binds.last?.harness == "claude" }
        #expect(binds.last == Bind(expected: "s-handoff", session: "s-handoff", harness: "claude"), "\(binds)")
        #expect(Self.icon(store) == Self.mark("claude"), "the tab does not draw the Claude mark after the switch")
    }

    /// Open Chat: the tab is created with its session (no harness); the pane's attach names the
    /// harness and a bind of that same session records it. A reply for another session changes nothing.
    @Test func anOpenedChatRecordsTheHarnessItsAttachNames() async throws {
        let store = Self.store(session: "s-open")
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        var binds: [Bind] = []
        Self.wired(tabs, store) { binds.append($0) }
        let key = try #require(store.tab(surface: 1)?.id)
        let view = try #require(tabs.view(for: key))
        #expect(Self.icon(store) != Self.mark("claude"))

        view.model.transport.sessions.observeFolder(Self.attachReply("s-other", harness: "codex"), replyTo: "_acpmux/attach")
        view.model.transport.sessions.observeFolder(Self.attachReply("s-open", harness: "claude"), replyTo: "_acpmux/attach")
        await Self.settle { !binds.isEmpty }
        #expect(binds == [Bind(expected: "s-open", session: "s-open", harness: "claude")], "\(binds)")
        #expect(Self.icon(store) == Self.mark("claude"), "the opened chat does not draw the Claude mark")

        // The same harness again binds nothing.
        view.model.transport.sessions.observeFolder(Self.attachReply("s-open", harness: "claude"), replyTo: "_acpmux/attach")
        await Self.settle { binds.count > 1 }
        #expect(binds.count == 1, "\(binds)")
    }

    /// A tab resuming an outside chat stays that chat's tab while it shows it: its first session is
    /// the resume. Once the user switches the tab to another chat, a `cmux://agent` link or a pick
    /// of the outside chat must not reveal it (it shows something else now).
    @Test func switchingChatsReleasesTheAdoption() async throws {
        let store = Self.store(session: nil)
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        var binds: [Bind] = []
        Self.wired(tabs, store) { binds.append($0) }
        let key = try #require(store.tab(surface: 1)?.id)
        let adopt = AgentPaneAdopt(harness: "claude", agentSessionId: "outside-1")
        tabs.adoptions["claude:outside-1"] = key
        let view = try #require(tabs.view(for: key))
        #expect(tabs.tab(resuming: adopt) == key)

        _ = await view.model.respond(to: Self.persist("s-resume"))
        await Self.settle { !binds.isEmpty }
        #expect(tabs.tab(resuming: adopt) == key, "the resume itself released the adoption")

        _ = await view.model.respond(to: Self.persist("s-other"))
        await Self.settle { binds.count > 1 }
        #expect(tabs.tab(resuming: adopt) == nil, "a tab showing another chat still claims the outside chat")
    }

    @Test func anAdoptionSurvivesStoreRecreationAndNeedsAConnectedDaemon() throws {
        let defaults = UserDefaults()
        let store = Self.store(session: "outside-1")
        let first = Self.agentTabs(defaults: defaults)
        Self.wired(first, store) { _ in }
        let key = try #require(store.tab(surface: 1)?.id)
        let adopt = AgentPaneAdopt(harness: "claude", agentSessionId: "outside-1")
        first.adoptions["claude:outside-1"] = key

        let restored = Self.agentTabs(defaults: defaults)
        Self.wired(restored, store) { _ in }
        #expect(restored.tab(resuming: adopt) == key)
        store.connectionState = .disconnected("offline")
        #expect(restored.tab(resuming: adopt) == nil, "a stale restored tree must not win while offline")
    }
}
