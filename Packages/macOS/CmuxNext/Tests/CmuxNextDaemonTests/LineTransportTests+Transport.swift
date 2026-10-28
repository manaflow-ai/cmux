import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The transport on CmuxNextIPC: one deadline timer per connection, one JSON parse per reply,
/// O(1) waiters that keep the id-less error's oldest-request rule, 512 KiB socket buffers, and a bad message
/// that ends the connection.
extension LineTransportTests {
    private static func command(_ id: UInt64, _ cmd: String) -> Data {
        Data(#"{"id":\#(id),"cmd":"\#(cmd)"}"#.utf8)
    }

    /// One pipelined line per command. Built inside the task that sends them: a line is not Sendable.
    private static func commandLines(_ commands: [String]) -> [PipelinedLine] {
        commands.map { cmd in PipelinedLine(cmd: DaemonCommandName(wire: cmd)) { command($0, cmd) } }
    }

    /// "ok", or the command and message of a refusal, or the error.
    private static func describe(_ outcome: Result<LineTransport.Response, any Error>) -> String {
        switch outcome {
        case .success: return "ok"
        case .failure(let error):
            guard case .command(let cmd, let message, _, _, _)? = error as? DaemonError else { return "\(error)" }
            return "\(cmd): \(message)"
        }
    }

    private static func timedOut(_ outcome: Result<LineTransport.Response, any Error>) -> Bool {
        guard case .failure(let error) = outcome, case .timedOut? = error as? DaemonError else { return false }
        return true
    }

    private func open(_ daemon: FakeDaemon, stats: DaemonWireStats? = nil,
                      clock: any Clock<Duration> = ContinuousClock()) throws -> LineTransport {
        let transport = try LineTransport(path: daemon.path, role: .control, stats: stats, clock: clock)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        return transport
    }

    /// Three requests with deadlines 1 s, 2 s and 3 s out ask the clock for one sleep, the earliest; each fire
    /// fails what is due and arms the next one. A reply to the request the timer is armed for moves the timer
    /// to the next deadline at once, so no fire comes for it. A timer per request asked for three sleeps at once.
    @Test func oneTimerServesEveryDeadlineOfAConnection() async throws {
        let clock = ManualClock()
        let daemon = try FakeDaemon()
        let transport = try open(daemon, clock: clock)
        defer { transport.close() }
        var tasks: [Task<LineTransport.Response, any Error>] = []
        var ids: [UInt64] = []
        for seconds in 1...3 {
            let cmd = "wait-\(seconds)"
            tasks.append(Task { try await transport.request(cmd: DaemonCommandName(wire: cmd), timeout: .seconds(seconds)) { Self.command($0, cmd) } })
            ids.append(try daemon.readRequestID())
        }
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1)
        #expect(clock.sleepRequests.map(\.deadline.offset) == [.seconds(1)])

        clock.advance(by: .seconds(1))
        #expect(Self.timedOut(await tasks[0].result))
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.map(\.deadline.offset) == [.seconds(1), .seconds(2)])

        daemon.write([#"{"id":\#(ids[1]),"ok":true,"data":{}}"#])
        _ = try await tasks[1].value
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.map(\.deadline.offset) == [.seconds(1), .seconds(2), .seconds(3)])
        #expect(clock.sleeperCount == 1, "only the 3 s sleep is left")

        clock.advance(by: .seconds(2))
        let last = await tasks[2].result
        guard case .failure(let error) = last, case .timedOut(let detail)? = error as? DaemonError else {
            Issue.record("the 3 s request ended with \(last)")
            return
        }
        #expect(detail.hasPrefix("wait-3 "))
        #expect(clock.sleeperCount == 0, "nothing waits, so nothing is armed")
    }

    /// Requests answered before their deadline leave no timer: the last reply cancels the one sleep, so the
    /// connection gets no wakeup at the deadline.
    @Test func answeredRequestsLeaveNoTimerArmed() async throws {
        let clock = ManualClock()
        let daemon = try FakeDaemon()
        let transport = try open(daemon, clock: clock)
        defer { transport.close() }
        var tasks: [Task<LineTransport.Response, any Error>] = []
        var ids: [UInt64] = []
        for cmd in ["first", "second"] {
            tasks.append(Task { try await transport.request(cmd: DaemonCommandName(wire: cmd), timeout: .seconds(2)) { Self.command($0, cmd) } })
            ids.append(try daemon.readRequestID())
        }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.map(\.deadline.offset) == [.seconds(2)])

        daemon.write([#"{"id":\#(ids[0]),"ok":true,"data":{}}"#])
        _ = try await tasks[0].value
        #expect(clock.sleeperCount == 1, "the second request still waits on the same deadline")

        daemon.write([#"{"id":\#(ids[1]),"ok":true,"data":{}}"#])
        _ = try await tasks[1].value
        #expect(clock.sleeperCount == 0, "nothing waits, so nothing is armed")
        clock.advance(by: .seconds(5))
        #expect(clock.sleepRequests.count == 1, "no fire came to re-arm")
    }

    /// A pipelined group shares one deadline: the clock is asked once and every member times out in its fire.
    @Test func aPipelinedGroupExpiresInOneFire() async throws {
        let clock = ManualClock()
        let daemon = try FakeDaemon()
        let transport = try open(daemon, clock: clock)
        defer { transport.close() }
        let results = Task { await transport.pipeline(Self.commandLines(["a", "b", "c"]), timeout: .seconds(5)) }
        for _ in 0..<3 { _ = try daemon.readRequestID() }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        let outcomes = await results.value
        #expect(outcomes.count == 3 && outcomes.allSatisfy(Self.timedOut))
        #expect(clock.sleepRequests.count == 1)
    }

    /// The transport routes each line without parsing it: an `ok:true` reply costs its reader's one decode,
    /// an error reply the transport's one decode of its error fields, and an event none until its handler reads it.
    @Test func eachReplyIsParsedOnce() async throws {
        let stats = DaemonWireStats()
        let daemon = try FakeDaemon()
        let transport = try open(daemon, stats: stats)
        defer { transport.close() }

        let answered = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.command($0, "identify") } }
        let answeredID = try daemon.readRequestID()
        daemon.write([#"{"event":"tree-changed","cause":"program"}"#, #"{"id":\#(answeredID),"ok":true,"data":{}}"#])
        let response = try await answered.value
        #expect(stats.snapshot().jsonDecodes == 0, "routing an event and a reply parsed one")
        _ = try WireCoding.decodeResponse(EmptyResponse.self, from: response)
        #expect(stats.snapshot().jsonDecodes == 1)

        let refused = Task { try await transport.request(cmd: "ping", timeout: nil) { Self.command($0, "ping") } }
        let refusedID = try daemon.readRequestID()
        daemon.write([#"{"id":"\#(refusedID)","ok":false,"error":{"code":"nope","message":"refused","retryable":true}}"#])
        let refusal = await refused.result
        guard case .failure(let error) = refusal, case .command(_, let message, let code, _, let retryable)? = error as? DaemonError else {
            Issue.record("the refusal is \(refusal)")
            return
        }
        #expect(message == "refused" && code == "nope" && retryable == true)
        #expect(stats.snapshot().jsonDecodes == 2)
    }

    /// Replies may come in any order by id; an id-less error still goes to the oldest request that waits.
    @Test func anIDLessErrorGoesToTheOldestWaitingRequest() async throws {
        let daemon = try FakeDaemon()
        let transport = try open(daemon)
        defer { transport.close() }
        let results = Task { await transport.pipeline(Self.commandLines(["a", "b", "c"]), timeout: nil) }
        let ids = try (0..<3).map { _ in try daemon.readRequestID() }
        daemon.write([#"{"id":\#(ids[1]),"ok":true,"data":{}}"#, #"{"ok":false,"error":"bad request 1"}"#,
                      #"{"ok":false,"error":"bad request 2"}"#])
        let outcomes = await results.value
        #expect(outcomes.map(Self.describe) == ["a: bad request 1", "ok", "c: bad request 2"])
    }

    /// Both socket buffers are at least 512 KiB, on the app's end of the connection.
    @Test func theSocketBuffersAreHalfAMebibyte() throws {
        let daemon = try FakeDaemon()
        let transport = try open(daemon)
        defer { transport.close() }
        let buffers = try #require(transport.socketBuffers)
        #expect(buffers.send >= LineTransport.socketBufferBytes)
        #expect(buffers.receive >= LineTransport.socketBufferBytes)
    }

    /// A line that is not UTF-8 is a bad message: the lines before it route, the connection closes with the
    /// reader's reason, and nothing after it is read.
    @Test func aLineThatIsNotUTF8EndsTheConnection() async throws {
        let script = #"""
        import sys
        print('{"ok":true}', file=sys.stderr, flush=True)
        sys.stdout.buffer.write(b'{"event":"first"}\n{"event":"\xc3\x28"}\n{"event":"after"}\n')
        sys.stdout.flush()
        sys.stdin.readline()
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let transport = try await LineTransport.open(path: "/tmp/cmux-bad-utf8-\(UUID().uuidString).sock", bridge: bridge,
                                                     role: .control, stats: nil)
        defer { transport.close() }
        let routed = ReplyEventOrderTests.Routed()
        let (closed, closing) = AsyncStream.makeStream(of: TransportCloseReason.self)
        transport.start(onEvent: { name, _, index in routed.record(name, index) },
                        onClose: { reason in
                            closing.yield(reason)
                            closing.finish()
                        })
        var iterator = closed.makeAsyncIterator()
        let reason = await iterator.next()
        #expect(reason == .lost("bad message: invalid_utf8"))
        #expect(routed.lines.withLock { $0.map(\.name) } == ["first"])
    }
}
