import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Code highlighting runs in a Worker the bundled page starts from its own origin. A worker gets
/// its policy from its own response, not from the page's meta tag, so the scheme handler serves
/// every script with a policy that allows no network: the worker can never open a connection.
@Suite struct AgentPaneHighlightWorkerTests {
    @Test func theBundledPageShipsItsHighlightWorker() throws {
        let page = try #require(AgentPaneView.bundledPage)
        let worker = page.deletingLastPathComponent().appendingPathComponent("highlight-worker.js")
        #expect(FileManager.default.fileExists(atPath: worker.path))
        let root = page.deletingLastPathComponent()
        let url = try #require(URL(string: "cmux-agent://pane/highlight-worker.js"))
        #expect(AgentPaneSchemeHandler.fileURL(for: url, root: root)?.lastPathComponent == "highlight-worker.js")
    }

    @Test func aScriptIsServedWithAPolicyThatAllowsNoNetwork() {
        let headers = AgentPaneSchemeHandler.headers(for: URL(fileURLWithPath: "/pane/highlight-worker.js"), length: 10)
        #expect(headers["Content-Security-Policy"] == "default-src 'none'")
        #expect(headers["Content-Type"] == "text/javascript")
        #expect(headers["X-Content-Type-Options"] == "nosniff")
    }

    /// The page document keeps its own policy (the meta tag); a second, stricter header policy
    /// would block the page's own scripts.
    @Test func thePageDocumentKeepsItsMetaPolicy() {
        let headers = AgentPaneSchemeHandler.headers(for: URL(fileURLWithPath: "/pane/index.html"), length: 10)
        #expect(headers["Content-Security-Policy"] == nil)
        #expect(headers["Content-Type"] == "text/html")
    }
}
