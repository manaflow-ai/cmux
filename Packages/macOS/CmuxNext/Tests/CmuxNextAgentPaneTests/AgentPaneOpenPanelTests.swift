import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// The composer's "Attach files" row clicks a file input. WebKit shows a chooser only when the web
/// view's UI delegate answers `runOpenPanelWith`; without one the click does nothing. Both hosts
/// (the pane's own WebKit host and the shared page host) answer it.
@MainActor
@Suite struct AgentPaneOpenPanelTests {
    @Test(arguments: [false, true])
    func aFileInputGetsTheOpenPanel(pageHost: Bool) throws {
        let index = try #require(AgentPaneView.bundledPage)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(index), pageHost: pageHost))
        defer { view.close() }
        let delegate = try #require(view.webView.uiDelegate)
        #expect(delegate.responds(to: #selector(WKUIDelegate.webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:))))
    }
}
