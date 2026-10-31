@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// P-RUST step 2 (R7, lead 2026-10-30): the app's Chats feed holds no copy of acpmux's chat index.
/// The watch's lines reach the main actor as messages; none may carry the index's chats (the
/// mirror whose copy and compare on main were the v2.2.9 hangs). acpmux answers each list with the
/// window or the rows it needs (`_acpmux/chats_window`, `_acpmux/chats`, `_acpmux/chat_open`).
@Suite struct ChatsFeedHoldsNoIndexTests {
    static let indexSize = 3000

    static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func chat(_ i: Int) -> [String: Any] {
        ["key": "claude-code:s\(i)", "sessionId": "s\(i)", "harness": "claude-code", "title": "chat \(i)",
         "cwd": "/work/p\(i % 50)", "updatedMs": 1_800_000_000_000 - i * 1000]
    }

    /// The `AcpmuxChat` values `value` holds anywhere inside it (stored properties, enum payloads,
    /// collections), by reflection, so the count needs no API of the type it reads.
    static func chats(in value: Any) -> Int {
        if value is AcpmuxChat { return 1 }
        return Mirror(reflecting: value).children.reduce(0) { $0 + chats(in: $1.value) }
    }

    @Test func theWatchPageReachesMainWithNoChatOfTheIndex() throws {
        let page = try Self.line(["jsonrpc": "2.0", "id": 2,
                                  "result": ["ready": true, "enabled": true, "seq": 7, "chats": (0..<Self.indexSize).map(Self.chat)]])
        let message = ChatsFeed.Message(line: page)
        #expect(Self.chats(in: message as Any) == 0, "the main actor gets the index's chats")
    }

    @Test func anIndexChangeReachesMainWithNoChat() throws {
        let change = try Self.line(["jsonrpc": "2.0", "method": "_acpmux/chat_changed",
                                    "params": ["kind": "upsert", "seq": 8, "key": "claude-code:s1", "chat": Self.chat(1)]])
        let message = ChatsFeed.Message(line: change)
        #expect(message != nil, "an index change still reaches the feed (the projects relay follows it)")
        #expect(Self.chats(in: message as Any) == 0, "the main actor gets the changed chat")
    }
}
