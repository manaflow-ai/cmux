import Foundation
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
}
