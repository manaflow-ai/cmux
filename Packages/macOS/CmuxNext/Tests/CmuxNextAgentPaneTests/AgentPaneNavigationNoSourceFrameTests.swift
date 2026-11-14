import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The agent pane's navigation delegate reads the same frames as a page's
/// (`PageNavigationNoSourceFrameTests`): macOS 14's WebKit may give no source frame, and the policy
/// is answered as with an unknown source instead of trapping on the nil request.
@Suite(.serialized)
@MainActor
struct AgentPaneNavigationNoSourceFrameTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor private final class Answers {
        var policies: [WKNavigationActionPolicy] = []
    }

    @Test func aNavigationWithNoSourceFrameGetsTheDecisionNotATrap() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-no-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let navigation = AgentPaneNavigation()
        navigation.view = view
        let answers = Answers()

        navigation.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: view.source.pageURL)) { answers.policies.append($0) }
        // Any other document in the main frame is cancelled, the same with no source frame.
        let artifact = try #require(URL(string: "cmux-agent://render/artifact"))
        navigation.webView(view.webView, decidePolicyFor: FakeNavigationAction(url: artifact)) { answers.policies.append($0) }
        #expect(answers.policies == [.allow, .cancel])
    }
}
