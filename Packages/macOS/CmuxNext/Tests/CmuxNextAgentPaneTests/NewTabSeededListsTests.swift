import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane
import CmuxNextPagesTestSupport

/// cx-uw104 at the pane's page: a New Tab page is made with the chats and recently closed items
/// the app already has (`AgentPageChats.seed`), before its page has loaded. The page installs its
/// bridge later and then asks for the handshake; the lists must reach it then, or the page says
/// "No chats yet" until the next index change.
@Suite(.serialized)
@MainActor
struct NewTabSeededListsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A page like the agent page: its bridge appears a moment after load, then it asks for the handshake.
    static let page = """
    <html><body><script>
    window.received = { chats: [], closed: [] };
    setTimeout(() => {
      window.cmuxAcpmuxBridge = {
        applyDeviceChats(chats) { window.received.chats = chats; },
        applyRecentlyClosed(items) { window.received.closed = items; },
      };
      window.webkit.messageHandlers.agentSession.postMessage({ method: "ready" }).catch(() => {});
    }, 300);
    </script></body></html>
    """

    @Test func listsSeededBeforeThePageLoadsReachItAtTheHandshake() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "seeded-lists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data(Self.page.utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), errors: DroppedErrors()))
        // What `AgentPageChats.seed` does as the page is made: the page is still loading.
        view.deviceChats = [AgentPaneDeviceChat(key: "claude-code:s-1", harness: "claude-code", title: "Fix the flaky upload test",
                                                updatedAt: Date(timeIntervalSince1970: 1_790_000_000))]
        view.recentlyClosed = AgentPaneClosedList([AgentPaneClosedItem(id: "closed:1", kind: .terminal, title: "zsh", detail: "~/repo",
                                                   closedAt: Date(timeIntervalSince1970: 1_790_000_000), icon: nil, isAvailable: true)])

        var received: [String: [[String: Any]]] = [:]
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            let value = try? await view.webView.evaluateJavaScript("JSON.stringify(window.received ?? null)") as? String
            let read = value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: [[String: Any]]] } ?? [:]
            received = read
            if !(read["chats"] ?? []).isEmpty, !(read["closed"] ?? []).isEmpty { break }
        }
        #expect((received["chats"] ?? []).map { $0["key"] as? String } == ["claude-code:s-1"],
                "the New Tab page never got the chats the app had when it was made")
        #expect((received["closed"] ?? []).map { $0["id"] as? String } == ["closed:1"],
                "the New Tab page never got the recently closed items the app had when it was made")
    }
}
