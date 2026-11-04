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
@MainActor
public final class TerminalFeedFixture {
    public static let shared = TerminalFeedFixture()
    private var feed: TerminalFeed?

    var mode: String? { ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_TERMINAL_FIXTURE"] }
    public var isRequested: Bool { mode == "1" || mode == "before" }

    public func startIfRequested(store: FeedStore = .shared) {
        guard isRequested, feed == nil, let tree = Self.tree() else { return }
        let feed = TerminalFeed(store: store)
        self.feed = feed
        store.replaceAll([])
        let rows = Self.rows(withTexts: mode == "1")
        feed.request = { command, _, _ in
            guard command == "list-notifications" else { return Data(#"{"ok":true,"data":{}}"#.utf8) }
            let body: [String: Any] = ["ok": true, "data": ["notifications": rows]]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
        feed.treeChanged(tree, macID: "mac-fixture", connection: 1)
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

    static func rows(withTexts: Bool) -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        func row(_ id: String, _ title: String, body: String = "", level: String = "info", surface: Int, ago: Int,
                 source: String = "agent", texts: [String: String] = [:]) -> [String: Any] {
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
                texts: ["message": approval, "prompt": "Ship the migration", "detail": approval]),
        ]
    }
}
#endif
