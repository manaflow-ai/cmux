import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneArtifactNavigationTests {
    @Test func artifactsCannotNavigateEvenToAnotherAllowedFrame() throws {
        let pane = AgentPaneSource.bundled(try #require(URL(string: "cmux-agent://pane/index.html")))
        let frame = try #require(URL(string: "cmux-agent://render/artifact"))
        #expect(AgentPaneNavigation.decision(for: frame, source: pane, userClicked: false, mainFrame: false) == .allow)
        for text in ["http://127.0.0.1:8080/leak", "https://example.com", "file:///tmp/private", "cmux-agent://render/frame", "about:srcdoc"] {
            let url = try #require(URL(string: text))
            for main in [true, false] {
                #expect(AgentPaneNavigation.decision(for: url, source: pane, userClicked: true, mainFrame: main,
                                                     sourceFrameURL: frame) == .cancel)
                #expect(AgentPaneNavigation.decision(for: url, source: pane, userClicked: false, mainFrame: main,
                                                     targetFrameURL: frame) == .cancel)
            }
        }
    }
}
