import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Holds every handshake until ``open()``.
private actor GatedHost: AgentPaneHostProviding {
    private var asked = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        asked = true
        waiting?.resume()
        waiting = nil
        await withCheckedContinuation { gate = $0 }
        return .mock
    }

    func waitUntilAsked() async {
        if asked { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
@Suite struct AgentPaneBridgeTests {
    private final class Weak {
        weak var view: AgentPaneView?
    }

    /// Closing a tab must free its pane (and web view) even while acpmux is
    /// still starting for the handshake, which can take up to 20 seconds.
    /// Drives `reply(to:)`, the path behind WebKit's message handler after
    /// its trust check (a test cannot make a WKScriptMessage).
    @Test(.timeLimit(.minutes(1))) func aClosedPaneIsFreedWhileItsHandshakeIsPending() async throws {
        let host = GatedHost()
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-bridge-test.html")
        let weak = Weak()
        var view: AgentPaneView? = try autoreleasepool {
            try #require(AgentPaneView(model: AgentPaneModel(host: host), source: .bundled(page)))
        }
        weak.view = view
        let bridge = try #require(view.map { AgentPaneBridge(view: $0) })
        let transport = Task { (await bridge.reply(to: .ready)["value"] as? [String: Any])?["transport"] as? String }
        await host.waitUntilAsked()
        autoreleasepool {
            view?.close()
            view = nil
        }
        #expect(weak.view == nil)
        await host.open()
        #expect(await transport.value == "mock")
    }

    /// The page installs its bridge in a React effect, which can run after
    /// the load finishes, so the theme pushed at didFinish was dropped and
    /// the pane kept its built-in dark colors and blue accent whatever the
    /// terminal theme. The page asks for the handshake once its bridge
    /// exists; the theme is pushed again then.
    @Test func askingForTheHandshakeAppliesTheTheme() async throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-bridge-test.html")
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: MockAgentPaneHost()), source: .bundled(page)))
        defer { view.close() }
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        _ = await AgentPaneBridge(view: view).reply(to: .ready)
        #expect(scripts.contains { $0.contains("cmuxAcpmuxBridge?.applyTheme(") })
    }
}
