import AppKit
import CmuxNextDesign
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `app.language` reaches the agent pane's old host (`cmux-agent://pane`, the default): its
/// document gets the same `__cmuxSetAppLanguage` call the page host's pages get, on load and on
/// every change, so the composer and machine picker switch language live. Before, only the page
/// host's ``PageWebView`` had it and the old host's chat stayed in the launch language.
@Suite(.serialized)
@MainActor
struct AgentPaneLanguageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Gives the main actor to the pane's followers until `done`, for at most 2 s.
    private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test(.timeLimit(.minutes(1)))
    func theOldHostsDocumentFollowsEveryChange() async throws {
        _ = NSApplication.shared
        let before = DesignSettings.shared.appLanguage
        defer { DesignSettings.shared.appLanguage = before }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        defer { view.close() }
        #expect(view.page == nil, "fixture: the old host")
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        DesignSettings.shared.appLanguage = "ja"
        try await Self.until { scripts.contains(PageWebView.languageScript("ja")) }
        #expect(scripts.contains(PageWebView.languageScript("ja")))

        DesignSettings.shared.appLanguage = nil
        try await Self.until { scripts.last == PageWebView.languageScript(nil) }
        #expect(scripts.last == PageWebView.languageScript(nil))
    }

    @Test func aLoadAndAHandshakeHandTheDocumentTheLanguage() throws {
        _ = NSApplication.shared
        let before = DesignSettings.shared.appLanguage
        defer { DesignSettings.shared.appLanguage = before }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(URL(filePath: "/dev/null"))))
        defer { view.close() }
        DesignSettings.shared.appLanguage = "de"
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.applyLanguage()
        #expect(scripts == [PageWebView.languageScript("de")])
    }
}
