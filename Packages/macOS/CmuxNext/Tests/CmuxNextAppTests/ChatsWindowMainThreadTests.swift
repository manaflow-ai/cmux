@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
import CmuxNextSidebar
import Foundation
import Testing

/// P-RUST item 2 (Lawrence's v2.2.9 hangs of 570 to 1,148 ms, 2026-10-30): with thousands of chats
/// in acpmux's index, one chat change must touch O(1) rows on the main thread. The hangs were the
/// whole-index mirror: `AcpmuxChatsStore.apply` copied every chat (the sidebar history held the same
/// storage) and `SidebarChatHistoryFeed.chats`'s setter compared and freed every chat.
@MainActor @Suite struct ChatsWindowMainThreadTests {
    static let indexSize = 3000

    static func chatJSON(_ i: Int) -> [String: Any] {
        ["key": "claude-code:s\(i)", "sessionId": "s\(i)", "harness": "claude-code", "title": "chat \(i)",
         "cwd": "/work/p\(i % 50)", "updatedMs": 1_800_000_000_000 - i * 1000]
    }

    /// The history feed's main-thread rows after one change to one chat of `indexSize`, through the
    /// app's wiring (`ChatsFeed.started`: every index change sets the history's index).
    @Test func oneChatChangeAmongThreeThousandTouchesOneRowOnMain() {
        let history = SidebarChatHistoryFeed()
        var index = AcpmuxChatsStore()
        index.reset(["chats": (0..<Self.indexSize).map(Self.chatJSON)])
        history.chats = index
        var changed = Self.chatJSON(Self.indexSize - 1)
        changed["updatedMs"] = 1_900_000_000_000
        index.apply(change: ["kind": "upsert", "key": "claude-code:s\(Self.indexSize - 1)", "chat": changed])
        history.chats = index
        // The rows the main thread holds for the sidebar history: its visible window at most.
        let held = history.chats.count
        #expect(held <= SidebarChatHistory.pageSize + 1, "the main thread holds \(held) chats for a window of \(SidebarChatHistory.pageSize)")
    }
}
