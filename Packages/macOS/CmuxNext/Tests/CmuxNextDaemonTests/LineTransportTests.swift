import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The app's `daemon.request` slices (p09-observability task 025): every request that waits for a reply writes
/// one async begin and one flow-out at its send, and one end with the same name and id when its reply, error or
/// timeout resolves it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LineTransportTests {
    typealias FakeDaemon = ReplyEventOrderTests.FakeDaemon

    /// The records a test runtime writes, in order.
    private final class Records: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var all: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with no ring that hands its records here, every category on or off.
        func runtime(on: Bool) -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(on ? .max : 0)
            return runtime
        }
    }

    private static func line(_ id: UInt64, _ cmd: String) -> Data {
        Data(#"{"id":\#(id),"cmd":"\#(cmd)"}"#.utf8)
    }

    private static func pipelined(_ commands: [String]) -> [PipelinedLine] {
        commands.map { cmd in PipelinedLine(cmd: DaemonCommandName(wire: cmd)) { line($0, cmd) } }
    }

    private func connect(_ daemon: FakeDaemon, _ trace: TraceRuntime) throws -> LineTransport {
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil, trace: trace)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        return transport
    }

    /// Begins and ends pair by name and async id, each end after its begin, and each begin has one flow-out that
    /// names its slice in `arg0`.
    private func expectMatchedPairs(_ records: [TraceRuntime.StubRecord], count: Int) {
        let begins = records.filter { $0.phase == .asyncBegin }
        let ends = records.filter { $0.phase == .asyncEnd }
        let flows = records.filter { $0.phase == .flowOut }
        #expect(begins.count == count && ends.count == count && flows.count == count && records.count == 3 * count)
        #expect(Set(begins.map(\.arg1)).count == count, "two requests share an async id")
        #expect(records.allSatisfy { $0.name == records[0].name })
        #expect((begins + ends).allSatisfy { $0.flags == .asyncID })
        #expect(flows.map(\.arg0) == begins.map(\.arg1), "a flow-out does not name its slice")
        for begin in begins {
            let end = ends.first { $0.arg1 == begin.arg1 }
            #expect(end.map { $0.tNanos >= begin.tNanos } == true, "a begin has no later end")
        }
    }

    @Test func aReplyAnErrorAndATimeoutEachEndTheirSlice() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))
        defer { transport.close() }

        let answered = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.line($0, "identify") } }
        let answeredID = try daemon.readRequestID()
        daemon.write([#"{"id":\#(answeredID),"ok":true,"data":{}}"#])
        _ = try await answered.value

        let refused = Task { try await transport.request(cmd: "machine.list", timeout: nil) { Self.line($0, "machine.list") } }
        let refusedID = try daemon.readRequestID()
        daemon.write([#"{"id":\#(refusedID),"ok":false,"error":"refused"}"#])
        await #expect(throws: DaemonError.self) { try await refused.value }

        await #expect(throws: DaemonError.self) {
            try await transport.request(cmd: "no-such-command", timeout: .milliseconds(20)) { Self.line($0, "no-such-command") }
        }

        let all = records.all
        expectMatchedPairs(all, count: 3)
        let begins = all.filter { $0.phase == .asyncBegin }
        #expect(begins.map(\.arg0) == [0, UInt64(DaemonCommandName.resourceBase), 0x8007])
        #expect(begins.map { $0.arg1 & LineTransport.requestIDMask } == [answeredID, refusedID, refusedID + 1])
        #expect(all.filter { $0.phase == .asyncEnd }.map(\.arg0) == [0, 1, 2], "outcomes: reply, error, timeout")
    }

    @Test func pipelinedRequestsEachOpenAndCloseOneSlice() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))
        defer { transport.close() }

        let results = Task { await transport.pipeline(Self.pipelined(["identify", "ping"]), timeout: nil) }
        let first = try daemon.readRequestID(), second = try daemon.readRequestID()
        daemon.write([#"{"id":\#(first),"ok":true,"data":{}}"#, #"{"id":\#(second),"ok":false,"error":"no"}"#])
        _ = await results.value

        expectMatchedPairs(records.all, count: 2)
        #expect(records.all.filter { $0.phase == .asyncEnd }.map(\.arg0) == [0, 1])
    }

    /// The second reply comes first: its slice ends at its own reply, before the first request's, although
    /// `pipeline` awaits the first slot first.
    @Test func aPipelinedSliceEndsAtItsOwnReplyNotAtAnEarlierOne() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))
        defer { transport.close() }

        let results = Task { await transport.pipeline(Self.pipelined(["identify", "ping"]), timeout: nil) }
        let first = try daemon.readRequestID(), second = try daemon.readRequestID()
        daemon.write([#"{"id":\#(second),"ok":true,"data":{}}"#, #"{"id":\#(first),"ok":true,"data":{}}"#])
        _ = await results.value

        expectMatchedPairs(records.all, count: 2)
        let ends = records.all.filter { $0.phase == .asyncEnd }
        #expect(ends.map { $0.arg1 & LineTransport.requestIDMask } == [second, first], "the fast reply waited for the slow one")
    }

    @Test func aClosedConnectionEndsTheSliceAsAnError() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))

        let pending = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.line($0, "identify") } }
        _ = try daemon.readRequestID()
        transport.close()
        await #expect(throws: DaemonError.self) { try await pending.value }

        expectMatchedPairs(records.all, count: 1)
        #expect(records.all.last?.arg0 == 1)
    }

    @Test func eachConnectionTakesAnAsyncScopeNoOtherConnectionHad() throws {
        let records = Records()
        let runtime = records.runtime(on: true)
        let firstDaemon = try FakeDaemon(), secondDaemon = try FakeDaemon()
        let first = try connect(firstDaemon, runtime)
        first.close()
        let second = try connect(secondDaemon, runtime)
        defer { second.close() }

        #expect(first.traceConnection == 1 << 40 && second.traceConnection == 2 << 40, "a reconnect reused a scope")
        #expect(runtime.nextAsyncScope() == 3)
    }

    @Test func eachRequestSendsItsFlowFromThePidAndTheRequestID() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))
        defer { transport.close() }

        let answered = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.line($0, "identify") } }
        let id = try daemon.readRequestID()
        daemon.write([#"{"id":\#(id),"ok":true,"data":{}}"#])
        _ = try await answered.value

        expectMatchedPairs(records.all, count: 1)
        let flow = records.all.first { $0.phase == .flowOut }
        #expect(flow?.arg1 == LineTransport.requestFlow(seed: LineTransport.requestFlowSeed(pid: getpid()), requestID: id))
        #expect(LineTransport.requestFlow(seed: LineTransport.requestFlowSeed(pid: 1234), requestID: 1) == 0xA3E9_5B7B_0AA2_937A,
                "FNV-1a 64 over the pid's 4 bytes then the request id's 8, little-endian")
    }

    @Test func withTheCategoryOffNothingIsWritten() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: false))
        defer { transport.close() }

        let answered = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.line($0, "identify") } }
        let id = try daemon.readRequestID()
        daemon.write([#"{"id":\#(id),"ok":true,"data":{}}"#])
        _ = try await answered.value
        #expect(records.all.isEmpty)
    }

    @Test func aWrittenBeginGetsItsEndAfterTheCategoryTurnsOff() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let runtime = records.runtime(on: true)
        let transport = try connect(daemon, runtime)
        defer { transport.close() }

        let answered = Task { try await transport.request(cmd: "identify", timeout: nil) { Self.line($0, "identify") } }
        let id = try daemon.readRequestID()
        runtime.setCategoryMask(0)
        daemon.write([#"{"id":\#(id),"ok":true,"data":{}}"#])
        _ = try await answered.value
        expectMatchedPairs(records.all, count: 1)
    }

    /// Each link kind reads and writes at its role's class, read back from the kernel on the reader thread: the
    /// terminal attach link (typed keys and their echo) at user-interactive, the control link (commands, replies,
    /// automation and sidebar events) one class below, so its churn never shares typing's class.
    @Test(arguments: [DaemonWireStats.Role.control, .terminalAttach])
    func eachLinkKindReadsAndWritesAtItsClass(role: DaemonWireStats.Role) async throws {
        let typing = role == .terminalAttach
        let reader = (typing ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED).rawValue
        let writer: DispatchQoS = typing ? .userInteractive : .userInitiated
        let daemon = try FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: role, stats: nil)
        try daemon.accept()
        defer { transport.close() }
        // The class the kernel runs the reader thread at, sampled inside its event handler.
        let (classes, continuation) = AsyncStream<UInt32>.makeStream()
        transport.start(onEvent: { _, _, _ in continuation.yield(qos_class_self().rawValue) }, onClose: { _ in })

        daemon.write([#"{"event":"probe"}"#])
        var iterator = classes.makeAsyncIterator()
        let observed = await iterator.next()

        #expect(observed == reader, "\(role.name) reader thread ran at \(observed.map { String($0, radix: 16) } ?? "nothing")")
        #expect(transport.writerQoS == writer, "\(role.name) writer queue")
    }

    @Test func namesMapToTheDaemonsMethodIDs() {
        let literal: DaemonCommandName = "identify"
        #expect(literal.id == 0 && literal.wire == "identify" && literal == DaemonCommandName(wire: "identify"))
        #expect(IdentifyRequest.commandName == literal && IdentifyRequest.command == "identify")
        #expect(DaemonCommandName(wire: "machine.list").id == DaemonCommandName.resourceBase)
        #expect(DaemonCommandName(wire: "session.journal.subscribe").id > DaemonCommandName.resourceBase)
        #expect(DaemonCommandName(wire: "browser-host-provider").id == 1, "a table row wins over its routed prefix")
        #expect(DaemonCommandName(wire: "no-such-command").id == 0x8007)
        #expect(DaemonCommandName(wire: "").id == 0x8007)
        #expect(DaemonCommandName.spells("identify", "identify"))
        #expect(!DaemonCommandName.spells("identify", "identifY"))
        #expect(DaemonCommandName.hash("") == 0xCBF2_9CE4_8422_2325, "FNV-1a's offset basis, as the generator's")
        #expect(DaemonCommandName.hash("a") == 0xAF63_DC4C_8601_EC8C, "FNV-1a 64 of \"a\"")
    }

    /// A name no table has takes request_spans.rs `RequestMethod::routed`'s id: `ROUTED_BASE` plus its prefix's class.
    @Test(arguments: [
        ("agent-session-events", 0x8005), ("agent-inventory", 0x8005), ("access-request-list", 0x8005),
        ("browser-foo", 0x8004), ("browser-runtime-start", 0x8004), ("agent", 0x8007), ("other-thing", 0x8007),
    ] as [(String, UInt16)])
    func routedNamesTakeTheDaemonsRoutedClass(name: String, id: UInt16) {
        #expect(DaemonCommandName(wire: name).id == id)
    }
}
