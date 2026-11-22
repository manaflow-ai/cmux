#if DEBUG
import CmuxMobileFeed
import CmuxMobileModel
import Foundation

/// Screenshot rig (DEBUG only): `CMUX_MOBILE_FEED_TERMINAL_FIXTURE=1` fills the Feed through the
/// real `TerminalFeed` path from a fixed Mac whose terminals run Claude Code and Codex, as the
/// Mac's daemon answers `list-notifications` now (each agent row with the texts it keeps in
/// memory). `=before` sends the same rows as a daemon before that change did (title and body
/// only), so a capture of each shows what a Claude Code terminal's events looked like and look
/// like now. The phone connects after the turns ended: no live event gives the texts.
/// `=states` shows a terminal approval card in each of its states (waiting, sending, allowed,
/// denied, refused because the terminal moved on, answered on the Mac), and `=asks` a waiting
/// approval and a waiting question, as the person sees them.
@MainActor
public final class TerminalFeedFixture {
    public static let shared = TerminalFeedFixture()
    private var feed: TerminalFeed?

    var mode: String? { ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_TERMINAL_FIXTURE"] }
    public var isRequested: Bool { ["1", "before", "states", "asks"].contains(mode ?? "") }

    public func startIfRequested(store: FeedStore = .shared) {
        guard isRequested, feed == nil, let tree = Self.tree() else { return }
        let feed = TerminalFeed(store: store)
        self.feed = feed
        store.replaceAll([])
        let rows: [[String: Any]] = switch mode {
        case "states": Self.stateRows()
        case "asks": Self.askRows()
        default: Self.rows(withTexts: mode == "1")
        }
        feed.request = { command, _, _ in
            guard command == "list-notifications" else { return Data(#"{"ok":true,"data":{}}"#.utf8) }
            let body: [String: Any] = ["ok": true, "data": ["notifications": rows]]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
        feed.treeChanged(tree, macID: "mac-fixture", connection: 1)
        guard mode == "states" else { return }
        // Each answer state of the same approval card, as FeedStore leaves it after a tap.
        Task { @MainActor in
            await feed.refresh()
            guard let base = store.item(id: TerminalFeed.itemID(macID: "mac-fixture", entry: "ntf_state_wait")) else { return }
            let states: [(String, (inout FeedItem) -> Void)] = [
                ("sending", { $0.pending = FeedStore.sendingAllow }),
                ("allowed", { $0.resolution = "Allowed once"; $0.isRead = true }),
                ("denied", { $0.resolution = "Denied" }),
                ("refused", { $0.error = String(localized: "The terminal isn't showing this approval anymore. Nothing was typed.") }),
                ("elsewhere", { $0.resolution = "Answered in the terminal" }),
            ]
            for (index, (name, change)) in states.enumerated() {
                var item = base
                item.id = base.id + "-" + name
                item.createdAt = base.createdAt.addingTimeInterval(-Double(index + 1) * 60)
                change(&item)
                store.upsert(item, atTop: false)
            }
        }
    }

    static func tree() -> DaemonTree? {
        let reply = Data("""
        {"ok":true,"data":{"workspaces":[{"id":4,"key":"ws-api","title":"api-server","screens":[{"id":3,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
          {"surface":1,"kind":"pty","title":"claude","cwd":"/Users/me/src/api-server"},
          {"surface":2,"kind":"pty","title":"claude","cwd":"/Users/me/src/api-server"},
          {"surface":3,"kind":"pty","title":"codex","cwd":"/Users/me/src/api-server"}
        ]}]}]}]}}
        """.utf8)
        var agents = AgentStates()
        agents.bySurface[1] = AgentState(state: "idle", agent: "claude")
        agents.bySurface[2] = AgentState(state: "blocked", agent: "claude")
        agents.bySurface[3] = AgentState(state: "idle", agent: "codex")
        return try? DaemonTree(reply: reply, macID: "mac-fixture", agents: agents)
    }

    static let claudeReply = """
    Fixed the login redirect loop.

    **What changed**
    - `auth/session.ts`: refresh the token *before* redirecting
    - `routes/login.tsx`: keep `returnTo` through the OAuth round trip
    - Added `login-redirect.test.ts` (fails on main, passes here)

    ```sh
    bun test login-redirect
    ```
    """
    static let approval = "Bash\n\n```\nbun run db:migrate --env staging\n```\n\nApply the pending migration to staging"

    static let migration = ["harness": "claude", "tool": "Bash", "command": "bun run db:migrate --env staging",
                            "description": "Apply the pending migration to staging"]

    static func row(_ id: String, _ title: String, body: String = "", level: String = "info", surface: Int, ago: Int,
                    source: String = "agent", extra: [String: Any] = [:]) -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var row: [String: Any] = ["id": id, "title": title, "body": body, "level": level, "terminal_id": "term_\(surface)",
                                  "surface": surface, "created_at_ms": now - ago * 1000, "source": source,
                                  "acknowledged": false]
        row.merge(extra) { _, new in new }
        return row
    }

    /// One waiting approval; the answer states are copies of its card (`startIfRequested`).
    static func stateRows() -> [[String: Any]] {
        [row("ntf_state_wait", "Claude needs approval", body: "Bash", level: "warning", surface: 2, ago: 30,
             extra: ["approval": migration, "message": approval, "detail": approval, "prompt": "Ship the migration"])]
    }

    /// A waiting approval (a path, no command) and a waiting question, with an error and an answer under them.
    static func askRows() -> [[String: Any]] {
        let question: [String: Any] = ["harness": "claude", "tool_use_id": "toolu_fixture", "questions": [[
            "question": "Which color should the banner be?", "header": "Banner color", "multiSelect": false,
            "options": [["label": "Red", "description": "Red banner"], ["label": "Green", "description": "Green banner"],
                        ["label": "Blue", "description": "Blue banner"]],
        ]]]
        let write = ["harness": "claude", "tool": "Write", "target": "/Users/me/src/api-server/.env.staging",
                     "description": "Add the staging database URL"]
        let error = "Exit code 1\nerror: script \"db:migrate\" exited with code 1\n  relation \"users\" already exists"
        return [
            row("ntf_ask_err", "Claude reported an error", body: "Bash", level: "error", surface: 1, ago: 600,
                extra: ["message": error, "detail": error, "prompt": "Run the migration"]),
            row("ntf_ask_done", "Claude finished", surface: 3, ago: 300,
                extra: ["message": claudeReply, "detail": claudeReply, "prompt": "Fix the login redirect loop"]),
            row("ntf_ask_write", "Claude needs approval", body: "Write", level: "warning", surface: 1, ago: 90,
                extra: ["approval": write]),
            row("ntf_ask_question", "Claude asked a question", body: "AskUserQuestion", level: "warning", surface: 2, ago: 20,
                extra: ["question": question]),
        ]
    }

    static func rows(withTexts: Bool) -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func row(_ id: String, _ title: String, body: String = "", level: String = "info", surface: Int, ago: Int,
                 source: String = "agent", texts: [String: Any] = [:]) -> [String: Any] {
            var row: [String: Any] = ["id": id, "title": title, "body": body, "level": level, "terminal_id": "term_\(surface)",
                                      "surface": surface, "created_at_ms": now - ago * 1000, "source": source,
                                      "acknowledged": false]
            if withTexts { row.merge(texts) { _, new in new } }
            return row
        }
        return [
            // Codex's own OSC 9 text (its reply), as the ledger holds it either way.
            row("ntf_codex", "Bumped ws to 8.18.2; npm audit is clean.", surface: 3, ago: 900, source: "terminal"),
            row("ntf_claude_done", "Claude finished", surface: 1, ago: 300,
                texts: ["message": claudeReply, "prompt": "Fix the login redirect loop", "detail": claudeReply]),
            // Claude Code's own OSC 7501 notice beside its hook's (an echo the Feed hides).
            row("ntf_claude_osc", "claude-code is done", surface: 1, ago: 300, source: "terminal"),
            row("ntf_claude_ask", "Claude needs approval", body: "Bash", level: "warning", surface: 2, ago: 60,
                texts: ["message": approval, "prompt": "Ship the migration", "detail": approval, "approval": migration]),
        ]
    }
}
#endif
