import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct NewTabStyleBridgeTests {
    @Test func theNewTabHandshakeCarriesTheDefaultStyle() throws {
        let page = AgentPaneNewTab(kind: .agent)
        let data = try JSONEncoder().encode(page)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["style"] as? String == "cmux")
    }

    @Test func thePageCanAskTheHostToPersistAStyle() {
        let request = AgentPaneRequest(body: [
            "method": "newTab.setStyle",
            "params": ["style": "classic"],
        ] as [String: Any])
        #expect(request != .unsupported("newTab.setStyle"))
        #expect(AgentPageOps.all.contains("cmux.agent.newTab.setStyle"))
    }
}
