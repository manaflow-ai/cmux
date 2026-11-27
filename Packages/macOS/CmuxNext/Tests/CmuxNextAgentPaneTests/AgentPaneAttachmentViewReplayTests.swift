import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextAgentPane
import CmuxNextSettings

/// A fresh legacy document starts with the web default, even when its native model did not change.
@Suite(.serialized)
@MainActor
struct AgentPaneAttachmentViewReplayTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func eachReadyRestoresThePersistedViewAfterTheDocumentResets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "attachment-view-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        let page = try #require(JSContext())
        page.evaluateScript("var window = { attachmentView: 'inline', cmuxAcpmuxComposer(value) { this.attachmentView = value.attachmentView; } };")
        view.evaluateScript = { page.evaluateScript($0) }
        var persisted = AgentPaneComposerSetting.fallback
        persisted.attachmentView = .strip
        persisted.push(to: view)
        #expect(page.evaluateScript("window.attachmentView")?.toString() == "strip")
        let bridge = AgentPaneBridge(view: view)
        for _ in 0..<2 {
            // A reload clears only JavaScript state. The native setting stays equal to the last push.
            page.evaluateScript("window.attachmentView = 'inline';")
            _ = await bridge.reply(to: .ready)
            #expect(page.evaluateScript("window.attachmentView")?.toString() == "strip")
        }
    }
}
