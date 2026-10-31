@testable import CmuxNextAgentPane
import CmuxNextDesign
import Foundation
import Testing

/// The New Tab chat store every page shares (webviews newtab/chatStore.ts, Leo 2026-10-19): Debug
/// Settings `newTab.privateChatLists` turns it off per page, and it ships off, so every page shares.
struct NewTabPrivateChatListsTests {
    @Test func theToggleShipsOffInDebugSettings() throws {
        #expect(AgentPaneTunables.newTabPrivateChatLists.key == "newTab.privateChatLists")
        #expect(AgentPaneTunables.newTabPrivateChatLists.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "newTab.privateChatLists" })
    }

    @Test func thePageContextNamesItOnlyWhenOn() throws {
        let page = AgentPaneNewTab(kind: .agent)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        let expected: Bool? = AgentPaneTunables.newTabPrivateChatLists.value ? true : nil
        #expect(json["privateChatLists"] as? Bool == expected)
    }
}
