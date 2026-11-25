@testable import CmuxNextAgentPane
import CmuxNextDesign
import Foundation
import Testing

/// The New Tab chat store every page shares (webviews newtab/chatStore.ts, Leo 2026-10-19): a page
/// of this Mac always shares it, so its context never names `privateChatLists`.
struct NewTabPrivateChatListsTests {
    @Test func thePageContextSharesTheChatList() throws {
        let page = AgentPaneNewTab(kind: .agent)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        #expect(json["privateChatLists"] == nil)
    }
}
