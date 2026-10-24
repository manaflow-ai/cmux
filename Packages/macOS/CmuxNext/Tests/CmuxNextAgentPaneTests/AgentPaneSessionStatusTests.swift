import CmuxNextDesign
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane
import CmuxNextPagesTestSupport

/// The in-session status cards (the live plan card and the recap card) are a Debug Settings toggle,
/// `agent.sessionStatus`, off by default. Turning it on in Debug Settings must reach an agent page
/// that is already open, without a reload, and a page made afterwards must start with it; turning
/// it off again must reach the open page too.
@Suite(.serialized)
@MainActor
struct AgentPaneSessionStatusTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A page like the agent page on the old host: its bridge records each session status push.
    static let page = """
    <html><body><script>
    window.received = [];
    window.cmuxAcpmuxBridge = { applySessionStatus(on) { window.received.push(on); } };
    </script></body></html>
    """

    private func pageReceived(_ view: AgentPaneView) async -> [Bool] {
        let value = try? await view.webView.evaluateJavaScript("JSON.stringify(window.received ?? [])") as? String
        return value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Bool] } ?? []
    }

    @Test func theDebugToggleReachesAnOpenAgentPageAndANewOne() async throws {
        let store = TunableStore.shared
        let key = AgentPaneTunables.sessionStatus.key
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        store.set(key, nil)
        defer { store.set(key, nil) }
        #expect(AgentPaneTunables.sessionStatus.defaultValue == false, "in-session status is on by default")

        let directory = FileManager.default.temporaryDirectory.appending(path: "session-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data(Self.page.utf8).write(to: file)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), errors: DroppedErrors()))
        #expect(!view.sessionStatus)

        try #require(store.set(key, .bool(true)) == .bool(true), "the store refused the toggle")
        for _ in 0..<400 where !view.sessionStatus { await Task.yield() }
        #expect(view.sessionStatus, "Debug Settings turned in-session status on, but the open agent page kept it off")
        var received: [Bool] = []
        for _ in 0..<50 where received.last != true {
            try await Task.sleep(for: .milliseconds(100))
            received = await pageReceived(view)
        }
        #expect(received.last == true, "the open page's bridge never got applySessionStatus(true)")
        #expect(AgentPanePageHost.currentEvents(view).filter { $0.kind == "sessionStatus" } == [.sessionStatus(true)],
                "a page that loads again on the page host would not get the toggle")

        let later = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), errors: DroppedErrors()))
        #expect(later.sessionStatus, "a page made with the toggle on starts with it off")

        store.set(key, nil)
        for _ in 0..<400 where view.sessionStatus { await Task.yield() }
        #expect(!view.sessionStatus, "Debug Settings turned in-session status off, but the open agent page kept it on")
        for _ in 0..<50 where received.last != false {
            try await Task.sleep(for: .milliseconds(100))
            received = await pageReceived(view)
        }
        #expect(received.last == false, "the open page's bridge never got applySessionStatus(false)")
    }
}
