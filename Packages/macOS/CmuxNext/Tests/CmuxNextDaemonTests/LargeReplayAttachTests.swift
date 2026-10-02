import Foundation
import Testing
@testable import CmuxNextDaemon

/// A terminal with a full scrollback replays up to the daemon's 10 MiB cap,
/// one JSON line of about 14 MB. The attach waits 10 s for its reply, which
/// follows that line, so reading the line must stay linear in its size: a
/// relaunch attaches every restored terminal while the machine is busy, and
/// a missed deadline closes the view for good.
@Suite(.timeLimit(.minutes(2))) struct LargeReplayAttachTests {
    @Test func aFullSizeReplayAttachesQuickly() async throws {
        let replay = Data(repeating: 0x61, count: 10 << 20).base64EncodedString()
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            guard request["cmd"]?.stringValue == "attach-surface" else { return [] }
            return [#"{"event":"vt-state","surface":7,"cols":80,"rows":24,"data":"\#(replay)"}"#,
                    #"{"id":\#(id),"ok":true,"data":{"lease":"L"}}"#]
        })
        defer { server.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: server.path), target: .init(surface: 7),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        let elapsed = clock.now - started
        var events = attachment.events.makeAsyncIterator()
        guard case .replay(let decoded)? = await events.next() else {
            Issue.record("attach did not start with a replay")
            return
        }
        attachment.detachNow()
        #expect(decoded.data.count == 10 << 20)
        // Linear reading takes well under a second in a debug build; the
        // quadratic newline scan took many seconds.
        #expect(elapsed < .seconds(3), "a 10 MiB replay took \(elapsed) to attach")
    }
}
