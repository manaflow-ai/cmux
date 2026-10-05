import AppKit
import Foundation
import Testing
import WebKit
@testable import CmuxNextAgentPane

private actor TicketHost: AgentPaneHostProviding {
    let url: URL
    init(url: URL) { self.url = url }
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
        .acpmux(AcpmuxConnection(url: url, dashboardToken: "dash", localAppToken: nil), sessionId: sessionId)
    }
}

/// The real bundled pane, end to end (flag 2 with B1): the user switches harness, picks a mode and
/// an effort while the harness starts (one pick gesture each: the pane reserves each with its
/// pick's intent), and presses send (one send press: the queued prompt uses it live). All three
/// frames reach the daemon, no ticket does, and a replay of a ticket is refused.
@MainActor
@Suite(.serialized) struct AgentPaneTicketEndToEndTests {
    private func page(_ view: AgentPaneView, _ script: String) async -> Any? {
        try? await view.webView.evaluateJavaScript(script)
    }

    private func eventually(_ seconds: Double = 20, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test func heldModeAndEffortPicksAndAQueuedPromptPassWithOneGestureEach() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AgentPaneModel(host: TicketHost(url: server.url))
        model.transport.webModes = AcpmuxAskingModesFake.claude
        model.workspaceRoots = { [root.path] }
        let view = try #require(AgentPaneView(model: model))
        defer { view.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero

        #expect(await eventually { await page(view, "typeof window.cmuxAcpmuxActions?.['chat.new']") as? String == "function" },
                "the pane connected through the host")
        // The harness takes its time to start: its session/new reply waits.
        server.hold("session/new")
        _ = await page(view, "void window.cmuxAcpmuxActions['chat.new']({ harness: 'codex' }); true")
        #expect(await server.wait(seconds: 10) { $0.last?.frames.contains { $0.contains("session/new") } == true })
        // The pick: one gesture, reserved by the pane in the pick's own handler.
        model.transport.gestures.record()
        _ = await page(view, "void window.cmuxAcpmuxActions['chat.mode']({ modeId: 'plan' }); true")
        #expect(await eventually { model.transport.gestures.lastTicket != nil }, "the pane reserved the pick's gesture")
        let ticket = try #require(model.transport.gestures.lastTicket)
        // A second held pick, the effort: its own gesture and its own ticket.
        model.transport.gestures.record()
        _ = await page(view, "void window.cmuxAcpmuxActions['chat.effort']({ configId: 'effort', value: 'high' }); true")
        #expect(await eventually { model.transport.gestures.lastTicket != ticket }, "the pane reserved the effort pick's gesture")
        // The send press: the queued prompt uses it live.
        model.transport.gestures.record()
        _ = await page(view, "void window.cmuxAcpmuxActions['chat.send']({ text: 'hello', attachments: [] }); true")
        // The harness is up: the held mode, then the prompt.
        server.releaseHeld()
        let both = await server.wait(seconds: 20) { peers in
            let frames = peers.last?.frames ?? []
            return frames.contains { $0.contains("session/set_mode") && $0.contains("plan") }
                && frames.contains { $0.contains("session/set_config_option") && $0.contains("high") }
                && frames.contains { $0.contains("session/prompt") }
        }
        let frames = server.peers.last?.frames ?? []
        #expect(both, "both the held pick and the queued prompt reached the daemon: \(frames.map { String($0.prefix(80)) })")
        #expect(!frames.contains { $0.contains("cmuxGesture") }, "the ticket never reaches the daemon")
        // A replayed ticket is refused.
        let connection = try #require(model.transport.connection)
        let replay = #"{"jsonrpc":"2.0","id":9001,"method":"session/set_mode","params":{"sessionId":"s-new","modeId":"plan","_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await model.transport.send(connection: connection, frames: [replay]) == .gestureRequired)
    }
}
