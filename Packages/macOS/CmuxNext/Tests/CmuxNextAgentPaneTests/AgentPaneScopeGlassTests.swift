import AppKit
import CmuxNextDesign
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

/// Leo 2026-10-21: "I LOAD IN AND IT'S A BLACK SCREEN". A workspace with a background picture
/// (its own scope's, not the app's) at background-opacity 1 shows a see-through window, and the
/// terminal beside the chat stays clear over it. The agent chat read the APP scope's backdrop when
/// it pushed its theme (`applyTheme` ran outside its own scope), decided the window was opaque and
/// painted the theme background at full alpha over the picture.
@Suite(.serialized)
@MainActor
struct AgentPaneScopeGlassTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aChatInAScopeWithAPictureIsGlassNotTheOpaqueThemeColor() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scope-glass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))

        // Outside any picture (the app's scope, background-opacity 1) the chat paints its theme color.
        try #require(ThemeScope.app.backdropSelection == nil, "the test's app scope has a picture")
        view.applyTheme(force: true)
        try #require(view.webView.underPageBackgroundColor.alphaComponent == 1, "an opaque window's chat is not opaque")

        // The workspace's scope has a picture: the window is see-through there, and so is the chat.
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let scope = ThemeScope(level: .room)
        scope.root(workspace)
        scope.setBackdropSelection(try #require(BackdropSelection(id: "van-gogh-starry-night")))
        workspace.addSubview(view)
        view.applyTheme(force: true)
        #expect(view.webView.underPageBackgroundColor.alphaComponent == 0,
                "the chat painted its theme background over its workspace's picture")
        let page = view.performWithTheme { AgentPaneTheme.pageColor(view.themeTokens) }
        #expect(page.alpha == 0, "the chat's page background is opaque in a see-through window: \(page)")
    }
}
