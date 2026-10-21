@testable import CmuxHomeCore

/// The owner records `WireHomeSource` tests send and expect: one DM between
/// the user and Bob, as home-core writes them.
struct WireFixture {
    static let me = "user_ts_me"
    static let bob = "user_ts_bob"
    static let conversationID = "conv_0Y05MEWEFMQQB63VDHQB9MXAJT"
    static let conversation = ConversationID(conversationID)
    static let stream = "conv:\(conversationID)"

    static func head(rev: UInt64, lastSeq: UInt64 = 0, cursors: [String: UInt64] = [:]) -> HomeWireJSON {
        [
            "id": .string(conversationID), "kind": "dm", "title": "", "rev": .uint(rev), "last_seq": .uint(lastSeq),
            "created_at": "2026-10-20T10:00:00.000Z", "updated_at": "2026-10-20T10:00:00.000Z",
            "participants": [
                ["id": .string(me), "kind": "human", "display_name": "Me"],
                ["id": .string(bob), "kind": "human", "display_name": "Bob"],
            ],
            "read_cursors": .object(cursors.mapValues { .uint($0) }),
        ]
    }

    static func message(seq: UInt64, author: String = bob, text: String = "hello", reactions: [HomeWireJSON] = []) -> HomeWireJSON {
        [
            "id": .string("msg_\(seq)"), "conversation": .string(conversationID), "seq": .uint(seq),
            "client_msg_id": .string("client_\(seq)"), "author": .string(author),
            "parts": [["type": "text", "text": .string(text)]],
            "created_at": "2026-10-20T10:00:00.000Z", "reactions": .array(reactions),
        ]
    }

    static func snapshot(seq: UInt64, rev: UInt64, messages: [HomeWireJSON]) -> HomeWireJSON {
        [
            "t": "snapshot", "stream": .string(stream), "seq": .uint(seq), "state": head(rev: rev, lastSeq: messages.last?["seq"].uint ?? 0),
            "rows": ["table": "msg", "rows": .array(messages.map { ["key": $0["id"], "n": $0["seq"], "row": $0] })],
        ]
    }

    /// An event frame of the conversation: `op` by `actor`, with the new head and row writes.
    static func event(seq: UInt64, op: String, actor: String = bob, head: HomeWireJSON, messages: [HomeWireJSON] = []) -> HomeWireJSON {
        [
            "t": "event", "stream": .string(stream), "seq": .uint(seq), "tx": .string("tx_\(seq)"), "op": .string(op),
            "actor": ["user": .string(actor)], "at": 0,
            "effects": [
                "state": head,
                "writes": .array(messages.map { ["op": "upsert", "table": "msg", "key": $0["id"], "n": $0["seq"], "row": $0] }),
            ],
        ]
    }

    static func entry(lastSeq: UInt64 = 1) -> HomeWireJSON {
        ["conversation": .string(conversationID), "kind": "dm", "dm_peer": .string(bob), "last_seq": .uint(lastSeq),
         "unread": 0, "last_at": "2026-10-20T10:00:00.000Z"]
    }

    static func welcome(user: String = me) -> HomeWireJSON {
        ["t": "welcome", "principal": ["user": .string(user)]]
    }
}
