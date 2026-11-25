import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// A Cloud machine's chat list draws the newest page of its chats, not every chat it ever ran.
@Suite struct CloudChatListTests {
    static func session(_ index: Int, peer: String? = nil) -> AcpmuxSession {
        var object: [String: JSONValue] = ["sessionId": .string("s\(index)"), "updatedAt": .number(Double(1_000_000 + index) * 1000)]
        if let peer { object["peer"] = .string(peer) }
        return AcpmuxSession(.object(object))!
    }

    @Test func drawsTheNewestPageAndGrowsByAPage() {
        let sessions = (0..<250).map { Self.session($0) } + [Self.session(9999, peer: "other")]
        let first = CloudChatList.newest(sessions, shown: CloudChatList.pageSize)
        #expect(first.rows.count == CloudChatList.pageSize)
        #expect(first.rows.first?.id == "s249")
        #expect(first.hasOlder)
        #expect(!first.rows.contains { $0.peer != nil })
        let all = CloudChatList.newest(sessions, shown: CloudChatList.pageSize * 3)
        #expect(all.rows.count == 250)
        #expect(all.rows.last?.id == "s0")
        #expect(!all.hasOlder)
    }
}
