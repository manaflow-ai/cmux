import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The app's pane answers its read-only peer status request from the existing
/// unix socket, preserving the daemon's cached minute reading without making
/// the WebSocket's LocalApp reply expose it.
struct AgentPaneTransportStatusTests {
    private static func socket() throws -> AcpmuxPaneSocket {
        let url = try #require(URL(string: "ws://127.0.0.1"))
        return AcpmuxPaneSocket(request: URLRequest(url: url),
                                limits: AgentPaneTransport.Limits(), options: AcpmuxPermissionOptions(),
                                sessions: AcpmuxPaneSessions(), ids: AcpmuxRequestIds(), signal: {})
    }

    private static func snapshot(path: String? = "/tmp/acpmux.sock", remote: Bool = false) -> AgentPaneTransport.Snapshot {
        AgentPaneTransport.Snapshot(isFirst: false, localAppToken: nil, socketPath: path,
                                     modeFields: nil, sessions: AcpmuxPaneSessions(),
                                     options: AcpmuxPermissionOptions(), remoteWire: remote)
    }

    @Test func onlyOneStatusReadCanRunPerConnection() {
        let slot = AcpmuxStatusReadSlot()
        #expect(slot.begin())
        #expect(!slot.begin())
        slot.end()
        #expect(slot.begin())
        slot.end()
    }

    @Test func localStatusRepliesRespectTheInboundByteLimit() throws {
        var limits = AgentPaneTransport.Limits()
        limits.maximumQueuedBytes = 8
        let url = try #require(URL(string: "ws://127.0.0.1"))
        let socket = AcpmuxPaneSocket(request: URLRequest(url: url), limits: limits,
                                     options: AcpmuxPermissionOptions(), sessions: AcpmuxPaneSessions(),
                                     ids: AcpmuxRequestIds(), signal: {})
        socket.receiveLocalReply("a reply larger than eight bytes")
        let batch = socket.take(maximumFrames: 10, maximumBytes: 100)
        #expect(batch.frames.isEmpty)
        #expect(batch.closed?.error == .inboundOverflow)
    }

    @Test func closingTheConnectionDropsLateStatusReplies() throws {
        let old = try Self.socket()
        #expect(old.statusRead.begin())
        old.close(code: 1000, reason: "reconnect", error: nil)
        old.receiveLocalReply(#"{"jsonrpc":"2.0","id":1,"result":{"peers":[]}}"#)
        #expect(old.queuedFrames == 0)
        let replacement = try Self.socket()
        #expect(replacement.statusRead.begin())
        old.statusRead.end()
        #expect(!replacement.statusRead.begin())
        replacement.statusRead.end()
    }

    @Test func localStatusUsesTheExistingUnixSocket() throws {
        let ids = AcpmuxRequestIds()
        let socket = try Self.socket()
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/status","params":{}}"#
        guard case .status(let pageID, let relayID, let path) = AgentPaneTransport.analyzeOne(
            frame, Self.snapshot(), socket: socket, ids: ids) else {
            Issue.record("local status was not intercepted")
            return
        }
        #expect(pageID == "7")
        #expect(relayID == 1)
        #expect(path == "/tmp/acpmux.sock")
    }

    @Test func aRemoteWireStillSendsStatusThroughItsWire() throws {
        let ids = AcpmuxRequestIds()
        let socket = try Self.socket()
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/status","params":{}}"#
        guard case .sent = AgentPaneTransport.analyzeOne(frame, Self.snapshot(remote: true), socket: socket, ids: ids) else {
            Issue.record("remote status was intercepted locally")
            return
        }
    }

    @Test func statusWithUnknownParamsIsRefused() throws {
        let ids = AcpmuxRequestIds()
        let socket = try Self.socket()
        let frame = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/status","params":{"secret":"no"}}"#
        guard case .refuse = AgentPaneTransport.analyzeOne(frame, Self.snapshot(), socket: socket, ids: ids) else {
            Issue.record("status accepted unknown params")
            return
        }
    }

    @Test func statusCannotBeTheHandshakeFrame() throws {
        let ids = AcpmuxRequestIds()
        let socket = try Self.socket()
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/status","params":{}}"#
        guard case .refuse = AgentPaneTransport.analyzeOne(
            frame, Self.snapshot().withFirstFrame, socket: socket, ids: ids) else {
            Issue.record("status bypassed first-frame initialize rule")
            return
        }
    }
}

private extension AgentPaneTransport.Snapshot {
    var withFirstFrame: Self {
        Self(isFirst: true, localAppToken: localAppToken, socketPath: socketPath,
             modeFields: modeFields, sessions: sessions, options: options, remoteWire: remoteWire)
    }
}
