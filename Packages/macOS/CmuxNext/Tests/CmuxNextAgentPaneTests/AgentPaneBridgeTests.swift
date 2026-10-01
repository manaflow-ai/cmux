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
    @Test func aClosedPaneIsFreedWhileItsHandshakeIsPending() async throws {
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
}
