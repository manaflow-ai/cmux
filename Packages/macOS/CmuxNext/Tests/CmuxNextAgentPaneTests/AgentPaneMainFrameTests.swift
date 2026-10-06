import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pane's main frame stays on its page, and a link opens outside the pane only after a real
/// user gesture in the pane (WebKit's link-activated flag alone is not proof).
@MainActor
@Suite struct AgentPaneMainFrameTests {
    private var devServer: AgentPaneSource {
        get throws { .devServer(try #require(URL(string: "http://127.0.0.1:4176/"))) }
    }

    /// A relative link in a dev-server pane resolves to the dev server's origin; it must not load there.
    @Test func aDevServerPaneKeepsItsPageInTheMainFrame() throws {
        let source = try devServer
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/README.md"), source: source, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/src/x.ts"), source: source, userClicked: false) == .cancel)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/"), source: source, userClicked: false) == .allow)
        #expect(AgentPaneNavigation.decision(for: URL(string: "http://127.0.0.1:4176/?t=1#row-4"), source: source, userClicked: false) == .allow)
    }

    @Test func aLinkOpensOutsideOnlyAfterAGesture() throws {
        let gestures = AgentPaneUserGestures()
        var opened: [URL] = []
        let link = try #require(URL(string: "https://github.com/manaflow-ai/cmux"))
        #expect(!AgentPaneNavigation.openOutside(link, gestures: gestures) { opened.append($0) })
        gestures.record()
        #expect(AgentPaneNavigation.openOutside(link, gestures: gestures) { opened.append($0) })
        // One gesture opens one link.
        #expect(!AgentPaneNavigation.openOutside(link, gestures: gestures) { opened.append($0) })
        #expect(opened == [link])
    }

    @Test func onlyWebLinksOpenOutside() throws {
        let gestures = AgentPaneUserGestures()
        var opened: [URL] = []
        for string in ["file:///etc/hosts", "cmux-agent://pane/index.html", "javascript:alert(1)", "https://u:p@example.com/"] {
            gestures.record()
            #expect(!AgentPaneNavigation.openOutside(try #require(URL(string: string)), gestures: gestures) { opened.append($0) }, "\(string)")
        }
        #expect(opened.isEmpty)
    }
}
