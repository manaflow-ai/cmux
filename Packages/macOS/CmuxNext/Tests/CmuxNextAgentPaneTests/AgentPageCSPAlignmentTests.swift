import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page host's header policy and the bundled page's meta policy say the same about the
/// network: no connection at all. The host's native transport carries acpmux, so the page needs
/// none, and neither policy may widen the other's if one is ever dropped.
@Suite struct AgentPageCSPAlignmentTests {
    private func directive(_ name: String, in policy: String) -> String? {
        policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(name + " ") }
    }

    @Test func theHeaderAllowsNoConnection() {
        let header = PageDescriptor.agent.csp.header
        #expect(directive("connect-src", in: header) == "connect-src 'none'")
        #expect(!header.contains("ws:"))
    }

    @Test func theHeaderAndTheBundledMetaTagAgreeOnConnections() throws {
        let page = try #require(AgentPaneView.bundledPage)
        let html = try String(contentsOf: page, encoding: .utf8)
        let marker = "http-equiv=\"Content-Security-Policy\" content=\""
        let start = try #require(html.range(of: marker)).upperBound
        let end = try #require(html[start...].firstIndex(of: "\""))
        let meta = String(html[start..<end])
        #expect(directive("connect-src", in: meta) == directive("connect-src", in: PageDescriptor.agent.csp.header))
        #expect(directive("frame-src", in: meta) == directive("frame-src", in: PageDescriptor.agent.csp.header))
    }
}
