import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneNavigationTests {
    private let page = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle/agent-pane/index.html")
    private var bundled: AgentPaneSource { .bundled(page) }
    private var devServer: AgentPaneSource {
        get throws { .devServer(try #require(URL(string: "http://127.0.0.1:4176/"))) }
    }

    @Test func onlyTheBundledPageLoadsInThePane() {
        #expect(AgentPaneNavigation.decision(for: page, source: bundled, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: page.absoluteString + "#row-4"), source: bundled, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(fileURLWithPath: "/etc/hosts"), source: bundled, userClicked: true) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "https://example.com"), source: bundled, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/"), source: bundled, userClicked: false) == .cancel)
    }

    @Test func aClickedWebLinkOpensOutsideThePane() throws {
        let link = try #require(URL(string: "https://github.com/manaflow-ai/cmux"))
        let dev = try devServer
        #expect(AgentPaneNavigation.decision(for: link, source: bundled, userClicked: true) == .openOutside(link))
        #expect(AgentPaneNavigation.decision(for: link, source: dev, userClicked: true) == .openOutside(link))
        #expect(AgentPaneNavigation.decision(for: URL(string: "javascript:alert(1)"), source: bundled, userClicked: true) == .cancel)
    }

    @Test func aDevServerPaneStaysOnItsExactOrigin() throws {
        let source = try devServer
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/"), source: source, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/?t=1#row-4"), source: source, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4177/"), source: source, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://localhost:4176/"), source: source, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "https://127.0.0.1:4176/"), source: source, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: page, source: source, userClicked: false) == .cancel)
    }

    @Test func handshakeRequestsMustComeFromThePanesOwnPage() throws {
        #expect(bundled.isTrusted(page))
        #expect(!bundled.isTrusted(URL(string: "https://evil.example/index.html")))
        #expect(!bundled.isTrusted(URL(string: "http://127.0.0.1:4176/")))
        #expect(!bundled.isTrusted(nil))
        let source = try devServer
        #expect(source.isTrusted(URL(string: "http://127.0.0.1:4176/")))
        #expect(!source.isTrusted(URL(string: "http://127.0.0.1:9999/")))
        #expect(!source.isTrusted(URL(string: "http://evil.example:4176/")))
        #expect(!source.isTrusted(page))
        #expect(!source.isTrusted(nil))
    }
}
