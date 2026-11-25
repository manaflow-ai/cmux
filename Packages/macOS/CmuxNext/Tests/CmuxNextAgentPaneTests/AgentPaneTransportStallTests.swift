import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A page that does not drain is not fed without bound. On Leo's NIGHTLY (9d514c685e48) a chat page
/// spun in a script and its renderer grew 80-120 MB a minute to 14 GB, 11 GB of it in PartitionAlloc:
/// the host pushed on every ack deadline (a quarter second, up to 4 MiB a push) to a page that read
/// none of it, and each push waited in the renderer. Now, past the unacked bounds the host stops
/// pushing, the socket holds the stream within its held bound and sheds past it, and the page's
/// next ack resumes: it gets one `_acpmux/lagged` and reads what it missed from the daemon.
@Suite(.serialized)
@MainActor
struct AgentPaneTransportStallTests {
    typealias Calls = AgentPaneHiddenHoldTests.Calls
    @MainActor final class Seqs { var values: [Int] = [] }

    /// Small bounds, a short deadline: a page that never acks hits the bounds within a second.
    static var limits: AgentPaneTransport.Limits {
        var limits = AgentPaneTransport.Limits()
        limits.ackDeadline = .milliseconds(5)
        limits.maximumBytesPerFlush = 8 << 10
        limits.maximumUnackedBytes = 32 << 10
        limits.maximumUnackedPushes = 1000
        limits.hiddenQueuedBytes = 16 << 10
        return limits
    }

    /// A page host page that never acks: its pushes are recorded, never applied.
    private static func silentPage(_ limits: AgentPaneTransport.Limits = limits) -> (AgentPaneTransport, Calls, Seqs) {
        let pacer = AgentPaneFramePacer(frames: AgentPaneHiddenPacingTests.Ticks(),
                                        fallback: AgentPaneHiddenHoldTests.SoonDeadline(), isHidden: { false })
        let transport = AgentPaneTransport(limits: limits, pacer: pacer)
        let calls = Calls()
        let seqs = Seqs()
        transport.deliver = { [weak transport] event, done in
            calls.deliver(event.frames)
            if let seq = event.seq { seqs.values.append(seq) }
            transport?.awaitAck(seq: event.seq ?? 0, done)
        }
        return (transport, calls, seqs)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Streams `count` bench frames from `first`, a few at a time, so they keep coming while the host decides.
    private static func stream(_ server: AcpmuxStandInServer, from first: Int, count: Int) async throws {
        for seq in first..<(first + count) {
            server.push(AcpmuxStandInServer.benchFrame(seq), to: 0)
            if seq % 50 == 0 { try await Task.sleep(for: .milliseconds(2)) }
        }
    }

    /// Opens, initializes, and has the page ack the initialize reply's push.
    private static func opened(_ server: AcpmuxStandInServer, limits: AgentPaneTransport.Limits = limits) async throws -> (AgentPaneTransport, Calls, Seqs, Int) {
        let (transport, calls, seqs) = silentPage(limits)
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        _ = await calls.call(containing: #""id":0"#)
        transport.acked(connection: id, seq: try #require(seqs.values.last), inputPending: false)
        return (transport, calls, seqs, id)
    }

    @Test func aPageThatNeverAcksIsHeldAtTheCapWhileTheStreamKeepsComing() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, _, _, _) = try await Self.opened(server)
        let limits = transport.limits
        let start = transport.pushedBytes
        // About 900 KB of stream, 28 times the unacked bound: before, every byte reached the page.
        try await Self.stream(server, from: 1, count: 3000)
        try await Self.waitUntil { transport.pageStalled }
        #expect(transport.pageStalled, "the host kept pushing a page that never acked")
        #expect(transport.stalls == 1)
        let atStall = transport.pushedBytes
        // At most one push past the bound went.
        #expect(atStall - start <= limits.maximumUnackedBytes + limits.maximumBytesPerFlush,
                "pushed \(atStall - start) bytes to a page that never acked")
        let socket = try #require(transport.socket)
        socket.waitForInboundPasses()
        let heldAtStall = socket.heldBytes
        // More stream, and many deadlines: nothing more is pushed, and the host's queue stays at its
        // bound: what waited when the page stopped (within the visible bound) or the held bound.
        try await Self.stream(server, from: 3001, count: 3000)
        try await Task.sleep(for: .milliseconds(200))
        socket.waitForInboundPasses()
        #expect(transport.pushedBytes == atStall, "pushed \(transport.pushedBytes - atStall) bytes past the stall")
        let frame = AcpmuxStandInServer.benchFrame(9999).utf8.count
        #expect(socket.heldBytes <= max(heldAtStall, limits.hiddenQueuedBytes) + frame,
                "the host's queue grew from \(heldAtStall) to \(socket.heldBytes) bytes while the page was stuck")
        #expect(transport.pageStalled)
    }

    /// Before and after in one harness: the same 6,000 frames (about 1.8 MB) to a page that never
    /// acks, with the unacked bounds off (the host before this change) and on.
    @Test func beforeAndAfterBytesPushedToAStuckPage() async throws {
        func run(_ limits: AgentPaneTransport.Limits) async throws -> Int {
            let server = AcpmuxStandInServer()
            try await server.start()
            defer { server.stop() }
            let (transport, _, _, _) = try await Self.opened(server, limits: limits)
            let start = transport.pushedBytes
            try await Self.stream(server, from: 1, count: 6000)
            try await Task.sleep(for: .milliseconds(300))
            return transport.pushedBytes - start
        }
        var unbounded = Self.limits
        unbounded.maximumUnackedBytes = .max
        unbounded.maximumUnackedPushes = .max
        let before = try await run(unbounded)
        let after = try await run(Self.limits)
        print("hung-page-backpressure: bytes pushed to a page that never acks, 6000 frames: before \(before) after \(after)")
        #expect(after <= Self.limits.maximumUnackedBytes + Self.limits.maximumBytesPerFlush)
        #expect(before > 4 * after, "before \(before), after \(after)")
    }

    @Test func thePagesNextAckResumesAndItReadsWhatItMissed() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, calls, seqs, id) = try await Self.opened(server)
        try await Self.stream(server, from: 1, count: 3000)
        try await Self.waitUntil { transport.pageStalled }
        #expect(transport.pageStalled)
        // Still stuck while more comes: this part is shed, the page reads it again later.
        try await Self.stream(server, from: 3001, count: 500)
        try #require(transport.socket).waitForInboundPasses()
        let before = calls.count
        // The page drains again, and acks each push from here; its ack of an old push is enough to resume.
        Self.ackEveryPush(transport, calls, seqs, id)
        transport.acked(connection: id, seq: try #require(seqs.values.first), inputPending: false)
        #expect(!transport.pageStalled)
        let lagged = await calls.call(containing: "_acpmux/lagged")
        #expect(calls.count > before)
        #expect(lagged.filter { $0.contains("_acpmux/lagged") }.count == 1)
        // The page reads from its cursor (direct.ts readMissedAfterLag): the daemon's answer reaches it.
        let missed = #"{"events":[{"seq":3499,"kind":"agent_message_chunk"},{"seq":3500,"kind":"agent_message_chunk"}],"hasMore":false}"#
        server.answer("_acpmux/events", with: missed)
        #expect(await transport.send(connection: id, frames: [
            #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/events","params":{"sessionId":"s","afterSeq":3498,"limit":5000}}"#,
        ]) == nil)
        let read = await calls.call(containing: #""id":9"#)
        let answer = try #require(read.first { $0.contains(#""id":9"#) })
        #expect(answer.contains(#""seq":3499"#) && answer.contains(#""seq":3500"#))
        #expect(transport.stalls == 1)
    }

    /// From here the page acks each push a turn after it lands, as a page that drains does.
    private static func ackEveryPush(_ transport: AgentPaneTransport, _ calls: Calls, _ seqs: Seqs, _ id: Int) {
        transport.deliver = { [weak transport] event, done in
            calls.deliver(event.frames)
            if let seq = event.seq { seqs.values.append(seq) }
            transport?.awaitAck(seq: event.seq ?? 0, done)
            guard let seq = event.seq else { return }
            // task-owner: the test page's ack, a turn later
            Task { @MainActor in transport?.acked(connection: id, seq: seq, inputPending: false) }
        }
    }

    @Test func aPageThatDrainsIsNeverStalled() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let (transport, calls, seqs, id) = try await Self.opened(server)
        Self.ackEveryPush(transport, calls, seqs, id)
        try await Self.stream(server, from: 1, count: 3000)
        _ = await calls.call(containing: #""s":3000,"#)
        #expect(transport.stalls == 0)
        #expect(!transport.pageStalled)
    }
}
