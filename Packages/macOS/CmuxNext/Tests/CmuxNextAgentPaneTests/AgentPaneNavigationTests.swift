import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneNavigationTests {
    private let page = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle/agent-pane/index.html")

    @Test func onlyTheBundledPageLoadsInThePane() {
        #expect(AgentPaneNavigation.decision(for: page, page: page, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: page.absoluteString + "#row-4"), page: page, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(fileURLWithPath: "/etc/hosts"), page: page, userClicked: true) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "https://example.com"), page: page, userClicked: false) == .cancel)
    }

    @Test func aClickedWebLinkOpensOutsideThePane() throws {
        let link = try #require(URL(string: "https://github.com/manaflow-ai/cmux"))
        #expect(AgentPaneNavigation.decision(for: link, page: page, userClicked: true) == .openOutside(link))
        #expect(AgentPaneNavigation.decision(for: URL(string: "javascript:alert(1)"), page: page, userClicked: true) == .cancel)
    }

    @Test func handshakeRequestsMustComeFromTheBundledPage() {
        #expect(AgentPaneBridge.isTrusted(page, page: page))
        #expect(!AgentPaneBridge.isTrusted(URL(string: "https://evil.example/index.html"), page: page))
        #expect(!AgentPaneBridge.isTrusted(nil, page: page))
    }
}
