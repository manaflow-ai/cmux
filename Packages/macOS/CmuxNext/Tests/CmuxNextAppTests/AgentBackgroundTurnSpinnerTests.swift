import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42447: a chat Claude Code woke on its own (a
/// background command ended) worked 18 minutes while its sidebar row showed no spinner, because
/// acpmux said `done` for a turn no one prompted. acpmux now names that turn (`backgroundTurn`)
/// and says `working`; the app's row spins from the same pushed summary, and the turn's end,
/// which never pings, rings no pane.
@MainActor @Suite(.serialized)
struct AgentBackgroundTurnSpinnerTests {
    private static let host = "install:background-turn"
    private static let session = "bg-chat-1"

    /// One `_acpmux/session_changed` as acpmux pushes it for the chat.
    private static func pushed(indicator: String?, backgroundTurn: [String: Any]?) -> [String: Any] {
        var summary: [String: Any] = ["sessionId": session, "turn": NSNull(), "lastTurn": ["status": "completed"]]
        if let indicator { summary["indicator"] = indicator }
        if let backgroundTurn { summary["backgroundTurn"] = backgroundTurn }
        return ["sessionId": session, "kind": "background_turn", "session": summary]
    }

    private static func apply(_ params: [String: Any], to turns: AgentTurnStateStore) throws {
        let change = try #require(AgentTurnStates.change(params))
        turns.apply(session: change.session, state: change.state, lastMessage: change.lastMessage, muted: change.muted,
                    title: change.title, detail: (params["session"] as? [String: Any]).flatMap(AgentChatDetail.of(summary:)))
    }

    @Test func aBackgroundTurnSpinsTheRowAndItsEndRingsNoPane() throws {
        _ = NSApplication.shared
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: Self.session, harness: "claude-sr2"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "#42403", screens: [screen])]))
        let tabs = try #require(store.workspaces.first).screens.flatMap(\.panes).flatMap(\.tabs)

        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        var rang: [String] = []
        turns.onTurnEnded = { rang.append($0) }
        let mapping = StatusMapping(turns: turns)

        // Between turns: the last one answered and was read; nothing spins.
        try Self.apply(Self.pushed(indicator: nil, backgroundTurn: nil), to: turns)
        #expect(!mapping.summaries(tabs: tabs).working, "an idle chat spun its row")

        // Claude Code runs a turn of its own: acpmux says working and names the turn.
        try Self.apply(Self.pushed(indicator: "working",
                                   backgroundTurn: ["id": "bg-5815", "trigger": "task_notification", "startedAt": 1_794_548_539_000]),
                       to: turns)
        #expect(mapping.summaries(tabs: tabs).working, "a chat in a background turn showed no spinner on its row")
        #expect(mapping.summaries(tabs: tabs).workspace.state.isWorking, "the row's merged status is not working")
        let ref = try #require(tabs.first?.agentSession)
        #expect(turns.detail(for: ref)?.turnStartedAtMs == 1_794_548_539_000, "the hover card has no start for the background turn")

        // It ends: the spinner goes, and the end rings no pane (a background turn never pings).
        try Self.apply(Self.pushed(indicator: nil, backgroundTurn: nil), to: turns)
        #expect(!mapping.summaries(tabs: tabs).working, "the spinner stayed after the background turn ended")
        #expect(rang.isEmpty, "a background turn's end rang its pane")

        // A prompted turn's end still rings as before.
        var prompted = Self.pushed(indicator: "working", backgroundTurn: nil)
        var summary = try #require(prompted["session"] as? [String: Any])
        summary["turn"] = ["startedAt": 1_794_548_600_000, "prompt": "fix it"]
        prompted["session"] = summary
        try Self.apply(prompted, to: turns)
        try Self.apply(Self.pushed(indicator: "done", backgroundTurn: nil), to: turns)
        #expect(rang == [Self.session], "a prompted turn's end no longer rang")
    }
}
