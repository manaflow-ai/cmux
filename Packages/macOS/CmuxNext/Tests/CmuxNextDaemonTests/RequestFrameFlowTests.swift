import CmuxNextCompat
import CmuxNextIPC
@testable import CmuxNextDaemon
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// A traced request sent as a REQUEST frame carries its `daemon.request` flow to the daemon (p05-ipc-180): the frame
/// sets FLOW with the flow id in front of the body, and the daemon's answer is the flow's flow-in on the app before
/// the slice ends, so the trace shows one flow app -> daemon -> app. A line, any request while the category is off,
/// and any request to a daemon that does not offer `ipc-request-flow-v1` carry no flow.
@Suite(.serialized, .timeLimit(.minutes(1))) struct RequestFrameFlowTests {
    typealias Fixture = DaemonHandshakeTests

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

    /// A transport to `daemon` that holds the frames grant for ``Fixture/served``, as the handshake leaves it with a
    /// daemon that does (`readsFlow`) or does not read a REQUEST frame's flow.
    private func framedTransport(_ daemon: WireDaemon, _ trace: TraceRuntime, readsFlow: Bool) async throws -> LineTransport {
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil, trace: trace)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        _ = try await transport.request(cmd: "set-client-info", timeout: .seconds(5)) { id in
            let info: [String: Any] = ["id": id, "cmd": "set-client-info",
                                       "capabilities": [WireNegotiation.framesCapability],
                                       "api_revision": WireNegotiation.apiRevision]
            return try JSONSerialization.data(withJSONObject: info)
        }
        transport.acceptFrames()
        let served = Set(Fixture.served.map { MethodID(rawValue: $0) })
        transport.adopt(WireNegotiation.Granted(grants: DaemonWireGrants(frames: true, streams: false),
                                                framing: FramedRequests(table: Fixture.table, served: served,
                                                                        readsFlow: readsFlow)))
        return transport
    }

    @Test func aTracedFramedRequestCarriesItsFlowAndItsAnswerIsTheFlowIn() async throws {
        let daemon = try WireDaemon(Fixture.daemon())
        defer { daemon.stop() }
        let records = Records()
        let transport = try await framedTransport(daemon, records.runtime(on: true), readsFlow: true)
        defer { transport.close() }
        let executor = DaemonRequestExecutor(transport: transport)

        _ = try await executor.perform(Fixture.Echo(text: "framed"), timeout: .seconds(5))
        // Served only as a line: no flow goes to the daemon, so none comes back.
        _ = try await executor.perform(Fixture.LinesOnly(text: "line"), timeout: .seconds(5))

        let seen = daemon.seen.withLock { $0 }
        let echo = try #require(seen.first { $0.cmd == "wire-echo" })
        let requestID = try #require(echo.requestID)
        let flow = LineTransport.requestFlow(seed: LineTransport.requestFlowSeed(pid: getpid()), requestID: UInt64(requestID))
        #expect(echo.framed && echo.flow == flow, "the REQUEST frame did not carry the request's flow")
        #expect(seen.first { $0.cmd == "wire-lines-only" }?.framed == false)

        let all = records.all
        let steps = all.enumerated().filter { $0.element.arg1 == flow && ($0.element.phase == .flowOut || $0.element.phase == .flowIn) }
        #expect(steps.map(\.element.phase) == [.flowOut, .flowIn], "send, then the daemon's answer")
        let asyncID = try #require(steps.first?.element.arg0)
        #expect(steps.last?.element.arg0 == asyncID, "the flow-in does not name the request's slice")
        let end = try #require(all.firstIndex { $0.phase == .asyncEnd && $0.arg1 == asyncID })
        #expect(steps.last.map { $0.offset < end } == true, "the slice ended before its flow-in")
        #expect(all.filter { $0.phase == .flowIn }.count == 1, "a line request wrote a flow-in")
        #expect(daemon.refusedFrames.withLock { $0 } == 0)
    }

    /// With the category off nothing is recorded, and the frame is the untraced one: no FLOW flag, no flow id.
    @Test func withTheCategoryOffTheFrameCarriesNoFlow() async throws {
        let daemon = try WireDaemon(Fixture.daemon())
        defer { daemon.stop() }
        let records = Records()
        let transport = try await framedTransport(daemon, records.runtime(on: false), readsFlow: true)
        defer { transport.close() }

        _ = try await DaemonRequestExecutor(transport: transport).perform(Fixture.Echo(text: "quiet"), timeout: .seconds(5))

        let echo = try #require(daemon.seen.withLock { $0 }.first { $0.cmd == "wire-echo" })
        #expect(echo.framed && echo.flow == nil)
        #expect(records.all.isEmpty)
    }

    /// A daemon from before p05-ipc-180 would read a flow id as the body: to one that does not offer the flow, a
    /// traced request goes framed without it, and its slice ends with no flow-in.
    @Test func aDaemonThatDoesNotReadTheFlowGetsNone() async throws {
        let daemon = try WireDaemon(Fixture.daemon())
        defer { daemon.stop() }
        let records = Records()
        let transport = try await framedTransport(daemon, records.runtime(on: true), readsFlow: false)
        defer { transport.close() }

        _ = try await DaemonRequestExecutor(transport: transport).perform(Fixture.Echo(text: "older"), timeout: .seconds(5))

        let echo = try #require(daemon.seen.withLock { $0 }.first { $0.cmd == "wire-echo" })
        #expect(echo.framed && echo.flow == nil)
        #expect(records.all.contains { $0.phase == .flowOut }, "the send still writes its flow-out")
        #expect(!records.all.contains { $0.phase == .flowIn })
    }

    /// The handshake reads the offer: frames with `ipc-request-flow-v1` carry the flow, frames without it do not.
    @Test(arguments: [true, false]) func theHandshakeReadsTheFlowOffer(offered: Bool) async throws {
        let offers = [Fixture.frames, Fixture.streams] + (offered ? [WireNegotiation.requestFlowCapability] : [])
        let daemon = try WireDaemon(Fixture.daemon(offers: offers))
        defer { daemon.stop() }
        let (connection, grants) = try await Fixture.connect(daemon, upgrades: Fixture.upgrades, hello: true)
        #expect(grants?.frames == true)
        let transport = try #require(await connection.ready?.transport)
        let framing = transport.state.withLock { $0.framing }
        #expect(framing?.readsFlow == offered)
        await connection.close()
    }
}
