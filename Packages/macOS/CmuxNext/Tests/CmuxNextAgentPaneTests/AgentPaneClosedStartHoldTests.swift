import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// cmux#63348, at the relay boundary (the page's frames into ``AgentPaneTransport``, out to the acpmux
/// stand-in): a `session/new` the daemon had not answered when the pane's socket ended held the tab
/// for good (``AcpmuxPaneReplacements``), so every Cloud start in it was refused at once as "A chat is
/// already starting in this tab" and its prompt never ran. On a loaded Mac the pane's socket drops
/// often (`socket failed … NSPOSIXErrorDomain 57`). Once that socket is closed and read to the end,
/// its start can be answered to no one, and the tab takes a Cloud start again.
@Suite(.serialized)
@MainActor
struct AgentPaneClosedStartHoldTests {
    static func startOut(_ pane: AgentPaneSlowStartPromptTests.Pane) async throws -> AcpmuxPaneSocket {
        pane.server.hold("session/new")
        pane.transport.gestures.record()
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"\#(pane.folder)","mcpServers":[]}}"#
        #expect(await pane.transport.send(connection: pane.id, frames: [frame]) == nil)
        #expect(await pane.transport.lineDrained(within: .seconds(10)))
        // Out, unanswered: a Cloud start or Sandboxed send is refused meanwhile, as before.
        #expect(pane.transport.replacements.holds)
        #expect(!pane.transport.replacements.admits())
        return try #require(pane.transport.socket)
    }

    @Test func aStartUnansweredWhenTheDaemonClosedTheSocketNoLongerHoldsTheTab() async throws {
        let pane = try await AgentPaneSlowStartPromptTests.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let socket = try await Self.startOut(pane)

        pane.server.pushThenClose([], to: 0)
        await socket.untilClosed()
        #expect(!pane.transport.replacements.holds, "a start no answer can reach held the tab after its socket closed")
        #expect(pane.transport.replacements.beginSandbox())
    }

    @Test func aStartUnansweredWhenThePaneReconnectedNoLongerHoldsTheTab() async throws {
        let pane = try await AgentPaneSlowStartPromptTests.pane()
        defer { pane.server.stop(); try? FileManager.default.removeItem(atPath: pane.folder) }
        let socket = try await Self.startOut(pane)

        // The pane's own reconnect closes the old socket (the host's close, not the daemon's).
        _ = try await pane.transport.open(AcpmuxConnection(url: pane.server.url, dashboardToken: "t", localAppToken: nil))
        await socket.untilClosed()
        #expect(!pane.transport.replacements.holds, "a start on the closed socket held the tab after the reconnect")
        #expect(pane.transport.replacements.beginSandbox(replacingOpened: true))
    }
    /// A chat on another machine (a Cloud machine's daemon behind the owning session): answers
    /// `initialize`, never answers a start or open, and ends when the test says so.
    final class DroppingWire: AcpmuxPaneWire, @unchecked Sendable { // crash-allow: test support; every access holds the lock
        private let state = Mutex<(onFrame: (@Sendable (String) -> Void)?, onClose: (@Sendable (Int, String) -> Void)?)>((nil, nil))

        func open(onFrame: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            state.withLock { $0 = (onFrame, onClose) }
        }

        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            completion(true)
            guard text.contains(#""method":"initialize""#),
                  let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            state.withLock { $0.onFrame }?(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"_meta":{"acpmux":{"origin":"remote"}}}}"#)
        }

        func cancel(code: Int, reason: String) {}

        /// The path ends by itself (the machine's link dropped).
        func drop() { state.withLock { $0.onClose }?(1006, "link lost") }
    }

    @Test func anOpenUnansweredWhenACloudMachinesLinkDroppedNoLongerHoldsTheTab() async throws {
        let wire = DroppingWire()
        let route = AgentPaneRemoteRoute(machine: "host", approvals: nil) { wire }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(.remote(route))
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: "\"origin\":\"remote\"")
        transport.sessions.add("s")
        transport.gestures.record()
        let attach = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/attach","params":{"sessionId":"s"}}"#
        #expect(await transport.send(connection: id, frames: [attach]) == nil)
        #expect(await transport.lineDrained(within: .seconds(10)))
        #expect(transport.replacements.holds)
        let socket = try #require(transport.socket)

        wire.drop()
        await socket.untilClosed()
        #expect(!transport.replacements.holds, "an open on the dropped link held the tab")
    }
}
