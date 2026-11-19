import CmuxMobileAgentChat
import CmuxMobileDesign
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

    /// The list's end: more held than shown loads as the reader nears it; all shown spins while the
    /// hub reads older chats, offers Try Again when that read stopped, and ends once all were read.
    @Test func theEndFollowsTheHubsRead() {
        #expect(CloudChatList.edge(hasOlder: true, listWhole: false, restStopped: false) == .more)
        #expect(CloudChatList.edge(hasOlder: true, listWhole: false, restStopped: true) == .more)
        #expect(CloudChatList.edge(hasOlder: true, listWhole: true, restStopped: false) == .more)
        #expect(CloudChatList.edge(hasOlder: false, listWhole: false, restStopped: false) == .loading)
        #expect(CloudChatList.edge(hasOlder: false, listWhole: true, restStopped: false) == .end)
        guard case .failed = CloudChatList.edge(hasOlder: false, listWhole: false, restStopped: true) else {
            Issue.record("a stopped read does not offer Try Again")
            return
        }
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
