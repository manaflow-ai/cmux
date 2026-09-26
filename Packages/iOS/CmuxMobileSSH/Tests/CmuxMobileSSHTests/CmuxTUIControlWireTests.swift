@testable import CmuxMobileSSH
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

/// Lab-free control-connection tests: a scripted peer answers the phone's
/// request lines with recorded cmux-tui reply shapes (`spec/commands.md`,
/// `spec/events.md`) over an in-memory channel, so the request params, the
/// handshake, and event routing are checked without a host or PTYs.
@Suite struct CmuxTUIControlWireTests {
    /// A hashed socket does not carry the session name; the control learns
    /// it from `identify`, and the resource scope resolves by that name.
    @Test func hashedSocketLearnsItsSessionFromIdentify() async throws {
        let long = String(repeating: "very-long-session-name-", count: 6)
        let peer = ScriptedCmuxTUIPeer()
        let control = try await peer.open(requestedSession: nil, reportedSession: long)
        #expect(await control.session == long)
        #expect(await control.server.session == long)
        await control.close()
    }

    /// Topology changes made elsewhere arrive on the subscription as
    /// `tree-changed` / `surface-exited`; interleaved `surface-output`
    /// notifications are not routed to it.
    @Test func subscriptionRoutesTreeChangesAndExits() async throws {
        let peer = ScriptedCmuxTUIPeer()
        let control = try await peer.open(requestedSession: "main", reportedSession: "main")
        async let subscribed = control.subscribe()
        let request = try await peer.nextRequest()
        #expect(request["cmd"] as? String == "subscribe")
        #expect(request["tree_events"] == nil)
        peer.reply(#"{"id":"\#(request["id"] as! String)","ok":true,"data":{}}"#)
        let events = try await subscribed
        peer.reply(#"{"event":"surface-output","surface":1}"#)
        peer.reply(#"{"event":"tree-changed"}"#)
        peer.reply(#"{"event":"title-changed","surface":1,"title":"vim"}"#)
        peer.reply(#"{"event":"surface-exited","surface":4}"#)
        peer.finish()
        var received: [CmuxTUIControlEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.treeChanged, .titleChanged(surface: 1, title: "vim"), .surfaceExited(surface: 4), .disconnected])
    }

    /// "Split Pane" sends `split` for the screen's active pane with the
    /// phone's grid and returns the new surface.
    @Test func splitSendsPaneDirectionAndGrid() async throws {
        let peer = ScriptedCmuxTUIPeer()
        let control = try await peer.open(requestedSession: "main", reportedSession: "main")
        async let surface = control.split(pane: 6, direction: .right, cols: 80, rows: 24)
        let request = try await peer.nextRequest()
        #expect(request["cmd"] as? String == "split")
        #expect(request["pane"] as? Int == 6)
        #expect(request["dir"] as? String == "right")
        #expect(request["cols"] as? Int == 80)
        #expect(request["rows"] as? Int == 24)
        peer.reply(#"{"id":"\#(request["id"] as! String)","ok":true,"data":{"surface":14}}"#)
        #expect(try await surface == 14)
        await control.close()
    }

    /// A rejected split reports the server's error.
    @Test func splitOfAMissingPaneFails() async throws {
        let peer = ScriptedCmuxTUIPeer()
        let control = try await peer.open(requestedSession: "main", reportedSession: "main")
        let surface = Task { try await control.split(pane: 99, direction: .down) }
        let request = try await peer.nextRequest()
        #expect(request["dir"] as? String == "down")
        #expect(request["cols"] == nil)
        peer.reply(#"{"id":"\#(request["id"] as! String)","ok":false,"error":"pane 99 not found"}"#)
        await #expect(throws: CmuxTUIError.self) { try await surface.value }
        await control.close()
    }
}

/// The server side of one relay channel: reads the phone's request lines
/// from the in-memory channel and feeds reply lines back as stdout.
final class ScriptedCmuxTUIPeer: Sendable {
    let channel = NIOAsyncTestingChannel()
    private let input: AsyncStream<SSHSessionEvent>.Continuation
    private let events: AsyncStream<SSHSessionEvent>

    init() {
        (events, input) = AsyncStream<SSHSessionEvent>.makeStream()
    }

    /// Opens a control and answers its handshake (`identify`, then
    /// `set-client-info`).
    func open(requestedSession: String?, reportedSession: String) async throws -> CmuxTUIControl {
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))
        let session = SSHSessionChannel(channel: channel, events: events)
        async let control = CmuxTUIControl.open(
            channel: session,
            session: requestedSession,
            clientName: "test",
            handshakeTimeout: .seconds(30)
        )
        let identify = try await nextRequest()
        #expect(identify["cmd"] as? String == "identify")
        let sessionJSON = String(decoding: try JSONEncoder().encode(reportedSession), as: UTF8.self)
        reply(#"{"id":"\#(identify["id"] as! String)","ok":true,"data":{"app":"cmux-tui","version":"0.13.4","protocol":12,"capabilities":["workspace-registry-v1","attach-initial-size","view-attachment-lease-v1"],"session":\#(sessionJSON),"pid":1}}"#)
        let info = try await nextRequest()
        #expect(info["cmd"] as? String == "set-client-info")
        reply(#"{"id":"\#(info["id"] as! String)","ok":true,"data":{}}"#)
        return try await control
    }

    /// The next request line the phone wrote, decoded.
    func nextRequest() async throws -> [String: Any] {
        let data = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
        guard case .byteBuffer(var buffer) = data.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            throw CmuxTUIError.malformedResponse("unreadable request")
        }
        return object
    }

    func reply(_ line: String) {
        input.yield(.stdout(Data((line + "\n").utf8)))
    }

    /// The relay exits: the channel closes.
    func finish() {
        input.yield(.closed)
        input.finish()
    }
}
