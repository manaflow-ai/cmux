import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// Host backpressure (chat-instant-under-load.md, piece 5). On the page host path the pacer's
/// completion fired on the next turn, not after the page ran the push, so a slow page got push
/// after push of up to 512 frames or 4 MiB each while the person typed. And a hidden pane got its
/// stream backlog every quarter second. Now the page acks each push (`transport.ack`), the next
/// one waits for the ack, a push is at most 64 frames or 64 KiB while the page reports input, and
/// a hidden pane's stream waits within a byte bound, is shed past it, and is read again on show.
@Suite(.serialized)
@MainActor
struct AgentPaneTransportAckTests {
    typealias Calls = AgentPaneHiddenHoldTests.Calls

    /// A page host page: no completion with the push, only the ack the test sends.
    private static func pageHostTransport(limits: AgentPaneTransport.Limits = Limits.longAck,
                                          hidden: Bool = false) -> (AgentPaneTransport, Calls, Seqs) {
        let pacer = AgentPaneFramePacer(frames: AgentPaneHiddenPacingTests.Ticks(),
                                        fallback: AgentPaneHiddenHoldTests.SoonDeadline(), isHidden: { hidden })
        let transport = AgentPaneTransport(limits: limits, pacer: pacer)
        transport.paneHidden = hidden
        let calls = Calls()
        let seqs = Seqs()
        transport.deliver = { [weak transport] event, done in
            calls.deliver(event.frames)
            if let seq = event.seq { seqs.values.append(seq) }
            transport?.awaitAck(seq: event.seq ?? 0, done)
        }
        return (transport, calls, seqs)
    }

    @MainActor final class Seqs { var values: [Int] = [] }

    /// Waits until `count` frames wait for the page, at most 10 s.
    private static func waitQueued(_ transport: AgentPaneTransport, _ count: Int) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while transport.queuedFrames < count, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(transport.queuedFrames >= count, "only \(transport.queuedFrames) of \(count) frames arrived")
    }

    enum Limits {
        /// An ack deadline the test never reaches: only the ack moves the next push.
        static var longAck: AgentPaneTransport.Limits {
            var limits = AgentPaneTransport.Limits()
            limits.ackDeadline = .seconds(30)
            return limits
        }
    }

    @Test func theNextPushWaitsForThePagesAck() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, calls, seqs) = Self.pageHostTransport()
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        // Unacked: frames that arrive wait, however long the page takes.
        server.push(AcpmuxStandInServer.benchFrame(1), to: 0)
        server.push(AcpmuxStandInServer.benchFrame(2), to: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.count == 1, "a push went before the page acked the one before it")
        // The page applied it: the waiting frames go, merged into one push.
        let first = try #require(seqs.values.last)
        transport.acked(connection: id, seq: first, inputPending: false)
        let next = await calls.call(containing: #""s":2,"#)
        #expect(next.contains { $0.contains(#""s":1,"#) }, "the frames that waited went in separate pushes")
        #expect(calls.count == 2)
        #expect(seqs.values.count == 2 && seqs.values[1] > first)
        // A stale or repeated ack moves nothing.
        transport.acked(connection: id, seq: first, inputPending: false)
        transport.acked(connection: id + 1, seq: seqs.values[1], inputPending: false)
        #expect(transport.acks == 2)
    }

    @Test func whileThePageHasInputAPushIsSmall() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, calls, seqs) = Self.pageHostTransport()
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        // 300 frames arrive while the page is busy with the first push and has a key pending.
        for seq in 1...300 { server.push(AcpmuxStandInServer.benchFrame(seq), to: 0) }
        try await Self.waitQueued(transport, 300)
        transport.acked(connection: id, seq: try #require(seqs.values.last), inputPending: true)
        let small = await calls.call(containing: #""s":1,"#)
        #expect(small.count == transport.limits.inputFramesPerFlush, "a push under input took \(small.count) frames")
        // The person stopped typing: the next push takes the rest at the full size.
        transport.acked(connection: id, seq: try #require(seqs.values.last), inputPending: false)
        let rest = await calls.call(containing: #""s":300,"#)
        #expect(rest.count == 300 - transport.limits.inputFramesPerFlush)
    }

    @Test func aPageThatNeverAcksIsPacedByTheDeadline() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        var limits = AgentPaneTransport.Limits()
        limits.ackDeadline = .milliseconds(20)
        let (transport, calls, _) = Self.pageHostTransport(limits: limits)
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        server.push(AcpmuxStandInServer.benchFrame(1), to: 0)
        _ = await calls.call(containing: #""s":1,"#)
        #expect(transport.ackTimeouts >= 1)
    }

    @Test func aHiddenPanesStreamBacklogWaitsForItToShow() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, calls, seqs) = Self.pageHostTransport(hidden: true)
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        transport.acked(connection: id, seq: try #require(seqs.values.last), inputPending: false)
        let before = calls.count
        // More than a full flush of stream: before, it reached the hidden page as a backlog.
        let full = transport.limits.maximumFramesPerFlush
        for seq in 1...(full + 9) { server.push(AcpmuxStandInServer.benchFrame(seq), to: 0) }
        try await Self.waitQueued(transport, full + 9)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.count == before, "a hidden pane got its stream backlog")
    }
}

/// A hidden pane's socket holds its stream within a byte bound and sheds past it; once shown, the
/// page gets what was held and one `_acpmux/lagged`, and reads the rest again from its cursor.
struct AgentPaneHiddenSocketBoundTests {
    private static func socket(_ limits: AgentPaneTransport.Limits) throws -> AcpmuxPaneSocket {
        let url = try #require(URL(string: "ws://127.0.0.1"))
        return AcpmuxPaneSocket(request: URLRequest(url: url), limits: limits, options: AcpmuxPermissionOptions(),
                                sessions: AcpmuxPaneSessions(), ids: AcpmuxRequestIds(), signal: {})
    }

    private static func chunk(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":\#(seq),"record":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}}}"#
    }

    @Test func aHiddenSocketShedsPastItsBoundAndNeverCallsItABacklog() throws {
        var limits = AgentPaneTransport.Limits()
        limits.hiddenQueuedFrames = 16
        let socket = try Self.socket(limits)
        socket.setHidden(true)
        for seq in 1...(limits.maximumFramesPerFlush + 100) { socket.receiveLocalReply(Self.chunk(seq)) }
        socket.waitForInboundPasses()
        #expect(socket.queuedFrames <= limits.hiddenQueuedFrames, "a hidden pane held \(socket.queuedFrames) frames")
        #expect(!socket.pageWaits, "a hidden pane's stream counted as a backlog its page waits on")
        // Still hidden: no lag marker yet, so the page reads what it missed once, on show.
        let held = socket.take(maximumFrames: 512, maximumBytes: 64 << 20)
        socket.waitForInboundPasses()
        #expect(!held.frames.contains { $0.contains("_acpmux/lagged") })
        socket.setHidden(false)
        socket.waitForInboundPasses()
        let shown = socket.take(maximumFrames: 512, maximumBytes: 64 << 20)
        #expect(shown.frames.filter { $0.contains("_acpmux/lagged") }.count == 1)
    }

    @Test func aVisibleSocketKeepsTheFullQueue() throws {
        var limits = AgentPaneTransport.Limits()
        limits.hiddenQueuedFrames = 16
        let socket = try Self.socket(limits)
        for seq in 1...600 { socket.receiveLocalReply(Self.chunk(seq)) }
        socket.waitForInboundPasses()
        #expect(socket.queuedFrames == 600)
        #expect(socket.pageWaits, "a visible pane's backlog")
    }
}
