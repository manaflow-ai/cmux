import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A finished turn's Feed card shows the agent's whole reply, not the session
/// summary's flattened 160-character preview: every agent's events read as
/// fully as a Chief subagent's report.
@MainActor
@Suite struct FeedFullReplyTests {
    nonisolated static let reply = "Fixed the login redirect.\n\n- `auth.ts`: keep the return URL\n- `session.ts`: refresh before redirect\n\n```sh\nbun test auth\n```"
    /// What acpmux's summary sends for that reply (`chats/activity.rs`): one flattened line.
    nonisolated static let preview = "Fixed the login redirect. - `auth.ts`: keep the return URL"

    static func mac() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            func chunk(_ seq: Int, _ text: String, _ message: String) -> String {
                let object: [String: Any] = [
                    "sessionId": "s1", "seq": seq, "dir": "in", "kind": "session/update",
                    "msg": ["method": "session/update", "params": ["update": [
                        "sessionUpdate": "agent_message_chunk", "messageId": message, "content": ["type": "text", "text": text],
                    ]]],
                ]
                return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"claude","harness":"claude","cwd":"/tmp/w","status":"idle","pendingPermissions":0,"lastSeq":9,"preview":"\#(preview)","lastTurn":{"status":"completed","turnId":"t1","endedAt":1000}}]}"#)]
            case "_acpmux/events":
                let full = Self.reply
                let cut = full.index(full.startIndex, offsetBy: 40)
                let events = [
                    #"{"sessionId":"s1","seq":1,"dir":"mux","kind":"user_message","msg":{"turnId":"t1","text":"fix login"}}"#,
                    chunk(2, "Looking at the auth code.", "m1"),
                    #"{"sessionId":"s1","seq":3,"dir":"in","kind":"session/update","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"c1","title":"Read auth.ts","kind":"read","status":"completed"}}}}"#,
                    chunk(4, String(full[..<cut]), "m2"),
                    #"{"sessionId":"s1","seq":5,"dir":"in","kind":"session/update","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"usage_update","used":10,"size":100}}}}"#,
                    chunk(6, String(full[cut...]), "m2"),
                    #"{"sessionId":"s1","seq":7,"dir":"mux","kind":"turn_result","msg":{"turnId":"t1","status":"completed"}}"#,
                ]
                return [reply(#"{"events":[\#(events.joined(separator: ","))]}"#)]
            default: return [reply("{}")]
            }
        }
    }

    @Test func turnCardShowsTheWholeLastReply() async throws {
        let hub = AcpmuxHub()
        await hub.bind(try await Self.mac().openChannel(service: "acpmux", args: [:]))
        let store = FeedStore(items: [])
        let feed = LiveFeed(store: store, hub: hub, place: { _ in nil })
        store.actions = feed

        await store.refresh()
        await feed.replyReads["turn-s1-t1"]?.value
        #expect(store.item(id: "turn-s1-t1")?.markdown == Self.reply)

        // A later read of the Mac (a reconnect, pull to refresh) keeps the whole reply.
        await store.refresh()
        #expect(store.item(id: "turn-s1-t1")?.markdown == Self.reply)
    }

    static func record(_ seq: Int, _ dir: String, _ kind: String, _ msg: JSONValue) -> JSONValue {
        .object(["sessionId": .string("s1"), "seq": .number(Double(seq)), "dir": .string(dir), "kind": .string(kind), "msg": msg])
    }

    static func chunk(_ seq: Int, _ text: String, _ message: String? = nil) -> JSONValue {
        var update: [String: JSONValue] = ["sessionUpdate": .string("agent_message_chunk"),
                                           "content": .object(["type": .string("text"), "text": .string(text)])]
        if let message { update["messageId"] = .string(message) }
        return record(seq, "in", "session/update", .object(["method": .string("session/update"), "params": .object(["update": .object(update)])]))
    }

    static func prompt(_ seq: Int, _ turn: String) -> JSONValue {
        record(seq, "mux", "user_message", .object(["turnId": .string(turn), "text": .string("go")]))
    }

    static func result(_ seq: Int, _ turn: String) -> JSONValue {
        record(seq, "mux", "turn_result", .object(["turnId": .string(turn), "status": .string("completed")]))
    }

    static func tool(_ seq: Int) -> JSONValue {
        record(seq, "in", "session/update", .object(["method": .string("session/update"), "params": .object(["update": .object([
            "sessionUpdate": .string("tool_call"), "toolCallId": .string("c\(seq)"), "title": .string("Read"),
            "kind": .string("read"), "status": .string("completed"),
        ])])]))
    }

    /// Only the end of a message on a full page (no prompt, nothing before it): its start may be
    /// missing, so the card keeps the preview; a page that reaches the session's start has it all.
    @Test func aPageWithOnlyTheEndOfTheMessageKeepsThePreview() {
        let tail = [Self.chunk(5, "end only"), Self.result(6, "t1")]
        #expect(LiveFeed.lastReply(tail, sessionID: "s1", turnID: "t1", complete: false) == nil)
        #expect(LiveFeed.lastReply(tail, sessionID: "s1", turnID: "t1", complete: true) == "end only")
    }

    /// A long turn whose prompt fell off the page: a tool call before the last message still
    /// says where that message starts.
    @Test func aToolCallMarksWhereTheLastMessageStarts() {
        let page = [Self.chunk(2, "earlier"), Self.tool(3), Self.chunk(4, "The "), Self.chunk(5, "answer."), Self.result(6, "t1")]
        #expect(LiveFeed.lastReply(page, sessionID: "s1", turnID: "t1", complete: false) == "The answer.")
    }

    /// The card of turn t1 shows t1's reply even when t2 already started: the read stops at t1's
    /// `turn_result`, and without it on the page nothing is shown.
    @Test func aCardShowsItsOwnTurnNotTheNextOne() {
        let page = [Self.prompt(1, "t1"), Self.chunk(2, "first answer"), Self.result(3, "t1"),
                    Self.prompt(4, "t2"), Self.chunk(5, "second, still writ")]
        #expect(LiveFeed.lastReply(page, sessionID: "s1", turnID: "t1", complete: false) == "first answer")
        #expect(LiveFeed.lastReply(page, sessionID: "s1", turnID: "t9", complete: false) == nil)
    }
}
