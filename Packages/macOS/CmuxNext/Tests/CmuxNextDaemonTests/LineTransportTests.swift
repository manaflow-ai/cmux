import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextTrace
import Foundation
import Testing

/// The app's `daemon.request` slices (p09-observability task 025): every request that waits for a reply writes
/// one async begin at its send and one end with the same name and id at its reply, error or timeout.
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

    private func connect(_ daemon: FakeDaemon, _ trace: TraceRuntime) throws -> LineTransport {
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil, trace: trace)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        return transport
    }

    /// Begins and ends pair by name and async id, each end after its begin.
    private func expectMatchedPairs(_ records: [TraceRuntime.StubRecord], count: Int) {
        let begins = records.filter { $0.phase == .asyncBegin }
        let ends = records.filter { $0.phase == .asyncEnd }
        #expect(begins.count == count && ends.count == count && records.count == 2 * count)
        #expect(Set(begins.map(\.arg1)).count == count, "two requests share an async id")
        #expect(records.allSatisfy { $0.flags == .asyncID && $0.name == records[0].name })
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
        #expect(begins.map(\.arg0) == [0, UInt64(DaemonCommandName.resourceBase), UInt64(DaemonCommandName.other.id)])
        #expect(begins.map { $0.arg1 & LineTransport.requestIDMask } == [answeredID, refusedID, refusedID + 1])
        #expect(all.filter { $0.phase == .asyncEnd }.map(\.arg0) == [0, 1, 2], "outcomes: reply, error, timeout")
    }

    @Test func pipelinedRequestsEachOpenAndCloseOneSlice() async throws {
        let records = Records()
        let daemon = try FakeDaemon()
        let transport = try connect(daemon, records.runtime(on: true))
        defer { transport.close() }

        let results = Task {
            await transport.pipeline(["identify", "ping"].map { cmd in PipelinedLine(cmd: cmd) { Self.line($0, cmd) } }, timeout: nil)
        }
        let first = try daemon.readRequestID(), second = try daemon.readRequestID()
        daemon.write([#"{"id":\#(first),"ok":true,"data":{}}"#, #"{"id":\#(second),"ok":false,"error":"no"}"#])
        _ = await results.value

        expectMatchedPairs(records.all, count: 2)
        #expect(records.all.filter { $0.phase == .asyncEnd }.map(\.arg0) == [0, 1])
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

    @Test func namesMapToTheDaemonsMethodIDs() {
        #expect(DaemonCommandName(wire: "identify").id == 0)
        #expect(DaemonCommandName(wire: "machine.list").id == DaemonCommandName.resourceBase)
        #expect(DaemonCommandName(wire: "session.journal.subscribe").id > DaemonCommandName.resourceBase)
        #expect(DaemonCommandName(wire: "no-such-command") == .other)
        #expect(DaemonCommandName(wire: "") == .other)
        #expect(DaemonCommandName(wire: "identify").isSpelled("identify"))
        #expect(!DaemonCommandName(wire: "identify").isSpelled("identifY"))
        #expect(DaemonCommandName.hash("") == 0xCBF2_9CE4_8422_2325, "FNV-1a's offset basis, as the generator's")
        #expect(DaemonCommandName.hash("a") == 0xAF63_DC4C_8601_EC8C, "FNV-1a 64 of \"a\"")
    }
}
