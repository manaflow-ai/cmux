import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// A chat with its native tab strip hidden still has a top webview strip. Its
/// focus ring must start below that strip, rather than drawing a second line
/// above it (Austin, 2026-10-23).
@MainActor @Suite(.serialized) struct AgentHiddenHeaderChromeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func hiddenAgentHeaderIsAChromeBand() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hidden-header-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Agent</body></html>".utf8).write(to: file)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "Chat")]),
                                   reveal: LaunchReveal(deadline: .zero))
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { page.close() }
        pane.hidesStrip = true
        pane.show(page)
        #expect(pane.paneHeaderHeight == PaneChromeMetrics.current.resolvedStripHeight(scale: 2))
    }
}
