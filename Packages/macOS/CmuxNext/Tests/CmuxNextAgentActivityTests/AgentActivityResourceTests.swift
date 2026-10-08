import Foundation
import Testing
@testable import CmuxNextAgentActivity

@Suite
struct AgentActivityResourceTests {
    @Test
    func bundledPageLoadsFromTheAgentActivityResourceDirectory() throws {
        let page = try #require(AgentActivityHostView.bundledPage)
        #expect(page.lastPathComponent == "index.html")
        #expect(page.deletingLastPathComponent().lastPathComponent == "agent-activity")
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("cmuxActivity"))
    }
}
