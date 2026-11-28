import CmuxMobileAgentChat
import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileLive

/// A Cloud machine's chat list draws the newest page of its chats, as acpmux orders and picks
/// them: the phone neither sorts nor filters (acpmux's own test of the order the Mac and the
/// phone share: `hub/session_pages.rs`, `the_mac_and_the_phone_read_one_order`).
@Suite struct CloudChatListTests {
    @Test func asksAcpmuxForThisMachinesNewestPage() {
        let params = CloudChatList.params(shown: CloudChatList.pageSize * 2)
        #expect(params["localOnly"] == .bool(true))
        // acpmux leaves out side chats and subagent sessions before it pages: the phone filters none.
        #expect(params["topLevelOnly"] == .bool(true))
        #expect(params["limit"]?.numberValue == Double(CloudChatList.pageSize * 2))
        #expect(params["cursor"] == nil)
    }

    /// The rows stay in the reply's order, even where the phone would have ordered them otherwise
    /// (a tie, a row with no `updatedAt` and a later `lastTurn.endedAt`).
    @Test func keepsTheOrderAcpmuxSent() throws {
        let reply: JSONValue = .object([
            "sessions": .array([
                .object(["sessionId": .string("b"), "updatedAt": .number(7)]),
                .object(["sessionId": .string("a"), "updatedAt": .number(9)]),
                .object(["sessionId": .string("c"), "lastTurn": .object(["endedAt": .number(99)])]),
            ]),
            "nextCursor": .string("k1.c"),
        ])
        let listed = try CloudChatList.listed(reply)
        #expect(listed.ids == ["b", "a", "c"])
        #expect(listed.hasOlder)
        let last = try CloudChatList.listed(.object(["sessions": .array([]), "nextCursor": .null]))
        #expect(last.ids.isEmpty)
        #expect(!last.hasOlder)
    }

    @Test func malformedReplyCannotReplaceKnownRowsWithEmpty() {
        for reply in [JSONValue.object([:]), .object(["sessions": .array([.object([:])])])] {
            #expect(throws: CocoaError.self) { try CloudChatList.listed(reply) }
        }
    }

    @Test func cachedPageRoundTripsDisplayRowsOnly() throws {
        let listed = try CloudChatList.listed(.object([
            "sessions": .array([
                .object([
                    "sessionId": .string("chat-1"),
                    "name": .string("Deploy"),
                    "harness": .string("claude"),
                    "cwd": .string("/private/project"),
                    "peer": .string("other-machine"),
                    "status": .string("working"),
                    "lastPrompt": .string("Ship the fix"),
                ])
            ])
        ]))
        let session = try #require(listed.rows["chat-1"])
        let page = CloudChatList.CachedPage(rows: [.init(session)], hasOlder: true)

        let encoded = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(CloudChatList.CachedPage.self, from: encoded)
        #expect(decoded == page)

        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["rows", "hasOlder"])
        let row = try #require((object["rows"] as? [[String: Any]])?.first)
        #expect(Set(row.keys) == ["id", "displayName", "lastPrompt"])
        #expect(row["id"] as? String == "chat-1")
        #expect(row["displayName"] as? String == "Deploy")
        #expect(row["lastPrompt"] as? String == "Ship the fix")
    }

    /// The list's end, from acpmux's page: more chats after it load as the reader nears the end; a
    /// page more spins while it is read, offers Try Again when that read failed, and the list ends
    /// once acpmux sent the machine's last chat.
    @Test func theEndFollowsAcpmuxsPage() {
        #expect(CloudChatList.edge(hasOlder: true, readingMore: false, failure: nil) == .more)
        #expect(CloudChatList.edge(hasOlder: true, readingMore: true, failure: nil) == .loading)
        #expect(CloudChatList.edge(hasOlder: false, readingMore: false, failure: nil) == .end)
        #expect(CloudChatList.edge(hasOlder: false, readingMore: true, failure: "timeout") == .end)
        guard case .failed = CloudChatList.edge(hasOlder: true, readingMore: true, failure: "timeout") else {
            Issue.record("a failed read of older chats does not offer Try Again")
            return
        }
    }

    static func session(_ index: Int) -> AcpmuxSession {
        AcpmuxSession(.object(["sessionId": .string("s\(index)"), "updatedAt": .number(Double(1_000_000 + index) * 1000)]))!
    }

    /// CLOUD-4: the chat asked for is unavailable only once the whole list was read without it.
    @Test func thePreferredChatIsUnavailableOnlyOnceTheWholeListLacksIt() {
        let held = Dictionary(uniqueKeysWithValues: (0..<100).map { ("s\($0)", Self.session($0)) })
        // The older pages are still on their way: an unlisted chat may be in them.
        #expect(!CloudChatList.preferredUnavailable("s150", sessions: held, listWhole: false, opened: false))
        // The whole list was read and it is not there.
        #expect(CloudChatList.preferredUnavailable("s150", sessions: held, listWhole: true, opened: false))
        // Listed, nothing asked for, or already opened: never reported.
        #expect(!CloudChatList.preferredUnavailable("s50", sessions: held, listWhole: true, opened: false))
        #expect(!CloudChatList.preferredUnavailable(nil, sessions: held, listWhole: true, opened: false))
        #expect(!CloudChatList.preferredUnavailable("s150", sessions: held, listWhole: true, opened: true))
    }
}
