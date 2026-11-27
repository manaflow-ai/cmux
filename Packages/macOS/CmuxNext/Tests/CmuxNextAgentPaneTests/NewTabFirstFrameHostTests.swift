@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A New Tab page names its machine on its first frame (Leo 2026-10-19: the page painted its
/// first frame as unexplored, then flipped): the context injected as the document commits carries
/// this Mac's name as `host`, which the page's machine chip reads before the handshake answers.
struct NewTabFirstFrameHostTests {
    @Test func thePageContextCarriesTheMachineNameWhenKnown() throws {
        var page = AgentPaneNewTab(kind: .agent, cwd: "/Users/you/src/atlas")
        #expect(try json(page)["host"] == nil)
        page.host = "cosmic-gray"
        #expect(try json(page)["host"] as? String == "cosmic-gray")
        // The handshake's copy decodes the same, so the page keeps one name across both.
        let decoded = try JSONDecoder().decode(AgentPaneNewTab.self, from: JSONEncoder().encode(page))
        #expect(decoded.host == "cosmic-gray")
    }

    private func json(_ page: AgentPaneNewTab) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }
}
