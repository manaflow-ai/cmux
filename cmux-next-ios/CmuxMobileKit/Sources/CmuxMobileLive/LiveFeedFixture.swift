#if DEBUG
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation

/// Screenshot rig (DEBUG only): `CMUX_MOBILE_FEED_LIVE_FIXTURE=1` fills the Feed through the
/// real `LiveFeed` path, from a fixed Mac (`MockMacLink`) with three agent chats, none of them
/// a Chief's: Claude Code finished with a long reply, Codex finished, and Claude Code waits on
/// an AskUserQuestion. A simulator capture then shows what a person sees for every agent's
/// events with no Mac paired.
@MainActor
public final class LiveFeedFixture {
    public static let shared = LiveFeedFixture()
    private var hub: AcpmuxHub?
    private var feed: LiveFeed?

    public var isRequested: Bool { ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_LIVE_FIXTURE"] == "1" }

    /// Starts the rig when requested: the Feed's items become the fixture Mac's.
    public func startIfRequested(store: FeedStore = .shared) {
        guard isRequested, hub == nil else { return }
        let hub = AcpmuxHub()
        let feed = LiveFeed(store: store, hub: hub, place: { session in
            LiveFeed.Place(workspaceID: "ws-\(session)", tabID: session, workspaceTitle: "api-server")
        })
        (self.hub, self.feed) = (hub, feed)
        store.replaceAll([])
        store.actions = feed
        // task-owner: LiveFeedFixture: one bind and one read at launch, DEBUG screenshots only.
        Task { @MainActor in
            guard let channel = try? await Self.mac().openChannel(service: "acpmux", args: [:]) else { return }
            await hub.bind(channel)
            await store.refresh()
        }
    }

    nonisolated static let claudeReply = """
    Fixed the login redirect loop.

    **What changed**
    - `auth/session.ts`: refresh the token *before* redirecting, so the guard sees a live session
    - `routes/login.tsx`: keep `returnTo` through the OAuth round trip
    - Added `login-redirect.test.ts` (fails on main, passes here)

    ```sh
    bun test login-redirect
    ```

    One open question: should an expired refresh token sign the person out, or retry once first?
    """
    nonisolated static let codexReply = """
    Bumped `ws` to 8.18.2 and regenerated the lockfile.

    1. `npm audit` is clean (was 2 high).
    2. The websocket reconnect tests pass locally (14/14).
    3. No API changes; nothing else needed updating.
    """

    nonisolated static func mac() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            func reply(_ result: Any) -> Data {
                let body: [String: Any] = ["jsonrpc": "2.0", "id": object["id"] ?? NSNull(), "result": result]
                return (try? JSONSerialization.data(withJSONObject: body)) ?? Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8)
            }
            switch method {
            case "initialize": return [reply(["protocolVersion": 1])]
            case "_acpmux/watch": return [reply(["sessions": sessions])]
            case "_acpmux/events": return [reply(["events": events(params)])]
            default: return [reply([String: Any]())]
            }
        }
    }

    nonisolated static var sessions: [[String: Any]] {
        let now = Date().timeIntervalSince1970 * 1000
        func session(_ id: String, _ name: String, _ harness: String, _ reply: String, prompt: String, ago: Double,
                     pending: Int = 0, status: String = "idle") -> [String: Any] {
            let flat = reply.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return ["sessionId": id, "name": name, "harness": harness, "cwd": "/Users/me/api-server", "status": status,
                    "pendingPermissions": pending, "lastSeq": 9, "lastPrompt": prompt,
                    // What acpmux's summary sends: the reply's first 160 characters, flattened.
                    "preview": String(flat.prefix(160)),
                    "lastTurn": ["status": "completed", "turnId": "t-\(id)", "endedAt": now - ago * 1000]]
        }
        return [
            session("s-claude", "claude", "claude", claudeReply, prompt: "fix the login redirect loop", ago: 60),
            session("s-codex", "codex", "codex", codexReply, prompt: "bump ws and fix the audit", ago: 600),
            session("s-ask", "claude-2", "claude", "Looking at the schema first.", prompt: "add a cache for sessions", ago: 1200,
                    pending: 1, status: "waiting"),
        ]
    }

    nonisolated static func events(_ params: [String: Any]) -> [[String: Any]] {
        let session = params["sessionId"] as? String ?? ""
        let kinds = params["kinds"] as? [String] ?? []
        if kinds.contains("permission_request") {
            guard session == "s-ask" else { return [] }
            let call: [String: Any] = [
                "toolCallId": "call-1", "title": "AskUserQuestion", "kind": "other",
                "rawInput": ["questions": [[
                    "question": "Where should the session cache live?", "header": "Cache",
                    "multiSelect": false,
                    "options": [["label": "Redis", "description": "Shared across instances; one more service to run"],
                                ["label": "In memory", "description": "Fastest; lost on deploy"],
                                ["label": "Postgres table", "description": "No new service; slower reads"]],
                ]]],
                "_meta": ["claude": ["tool": "AskUserQuestion"]],
            ]
            return [["sessionId": session, "seq": 8, "dir": "mux", "kind": "permission_request",
                     "msg": ["permissionId": "perm-cache", "request": ["sessionId": session, "toolCall": call, "options": [
                         ["optionId": "allow", "kind": "allow_once", "name": "Answer"],
                         ["optionId": "reject", "kind": "reject_once", "name": "Decline"]]]]]]
        }
        let text = session == "s-claude" ? claudeReply : session == "s-codex" ? codexReply : "Looking at the schema first."
        func chunk(_ seq: Int, _ text: String) -> [String: Any] {
            ["sessionId": session, "seq": seq, "dir": "in", "kind": "session/update",
             "msg": ["method": "session/update", "params": ["update": [
                 "sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": ["type": "text", "text": text]]]]]
        }
        let cut = text.index(text.startIndex, offsetBy: text.count / 2)
        return [
            ["sessionId": session, "seq": 1, "dir": "mux", "kind": "user_message", "msg": ["turnId": "t-\(session)", "text": "go"]],
            chunk(2, String(text[..<cut])), chunk(3, String(text[cut...])),
            ["sessionId": session, "seq": 4, "dir": "mux", "kind": "turn_result", "msg": ["turnId": "t-\(session)", "status": "completed"]],
        ]
    }
}
#endif
