import Foundation
import Testing
@testable import CmuxNextDaemon

/// A terminal with a full scrollback replays up to the daemon's 10 MiB cap,
/// one JSON line of about 14 MB. The attach waits 10 s for its reply, which
/// follows that line, so reading the line must stay linear in its size: a
/// relaunch attaches every restored terminal while the machine is busy, and
/// a missed deadline closes the view for good. `LineSplitterTests` checks the
/// linear bound by counting the bytes searched; this test checks that the
/// whole replay reaches the attach, without a wall-clock limit that a busy
/// machine fails (hosted run 37845131094: 3.02 s against 3 s).
@Suite(.timeLimit(.minutes(2))) struct LargeReplayAttachTests {
    @Test func aFullSizeReplayAttachesQuickly() async throws {
        let replay = Data(repeating: 0x61, count: 10 << 20).base64EncodedString()
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "attach-surface" else { return [] }
            return [#"{"event":"vt-state","surface":7,"cols":80,"rows":24,"data":"\#(replay)"}"#,
                    #"{"id":\#(id),"ok":true,"data":{"lease":"L"}}"#]
        })
        defer { server.stop() }
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: server.path), target: .init(surface: 7),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        var events = attachment.events.makeAsyncIterator()
        guard case .replay(let decoded)? = await events.next() else {
            Issue.record("attach did not start with a replay")
            return
        }
        attachment.detachNow()
        #expect(decoded.data.count == 10 << 20)
    }
}
