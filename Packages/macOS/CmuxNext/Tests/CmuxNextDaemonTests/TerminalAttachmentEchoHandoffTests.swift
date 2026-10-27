import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The attach reader's and the session loop's handoffs of a key's echo (p09-observability-102): the reader reads
/// the daemon's `output` event that names the press (`key.echo.line_out` taken), hands it on (`key.echo.app_transport_read`
/// queued), decodes it (`app.output.decoded`) and queues it with its marker; the loop takes the marker
/// (`key.echo.app_transport_read` taken) and hands it to the lane's router (`key.echo.main_actor` queued). An event
/// that names no press marks none of them.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TerminalAttachmentEchoHandoffTests {
    typealias FakeDaemon = ReplyEventOrderTests.FakeDaemon

    private static let surface = SurfaceID(rawValue: 3)

    /// The probe's `key.echo.*` handoffs and `key.flow` hops in the order they were written: `>` a flow out
    /// (queued), `<` a flow in (taken), a hop by its name; each with its flow.
    private nonisolated final class StepLog: Sendable {
        private let state = Mutex<[(step: String, flow: UInt64)]>([])
        let arrivals: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            let (arrivals, continuation) = AsyncStream<Void>.makeStream()
            self.arrivals = arrivals
            self.continuation = continuation
        }

        /// A runtime with every category on whose handoff records land here.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                guard let name = SignpostName(rawValue: record.name), String(describing: name).hasPrefix("key.echo.") else { return }
                switch record.phase {
                case .flowOut: append("\(name)>", record.arg1)
                case .flowIn: append("\(name)<", record.arg1)
                default: return
                }
            })
            runtime.setCategoryMask(SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }

        func append(_ step: String, _ flow: UInt64) {
            state.withLock { $0.append((step, flow)) }
        }

        func steps(_ flow: UInt64) -> [String] {
            state.withLock { $0 }.filter { $0.flow == flow }.map(\.step)
        }

        /// Forgets the steps so far (the press's own hops before its echo).
        func reset() {
            state.withLock { $0.removeAll() }
        }

        /// The reader handed an event on.
        func routed() { continuation.yield() }

        func waitForRoutes(_ count: Int) async {
            var seen = 0
            for await _ in arrivals {
                seen += 1
                if seen == count { return }
            }
        }
    }

    /// One key press on `key`, dispatched, written and sent; returns its flow.
    private func sentPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        return flow
    }

    @Test func anOutputThatNamesItsPressCarriesTheFlowFromTheReaderToTheLanesRouter() async throws {
        let log = StepLog()
        let probe = TypingLatencyProbe(path: nil, trace: log.runtime(), hopRecorder: { hop, flow in log.append(hop, flow) })
        probe.startFlows()
        defer { probe.stopFlows() }
        let flow = try sentPress(probe, on: probe.makeSurfaceKey())
        log.reset()

        let daemon = try FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil, probe: probe)
        try daemon.accept()
        let queue = TerminalEventQueue(recorder: nil)
        let decoder = transport.decoder
        transport.start(onEvent: { name, line, _ in
            if let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: Self.surface, decoder: decoder) {
                TerminalAttachment.enqueue(decoded.event, echoing: decoded.flow, on: queue, probe: probe)
            }
            log.routed()
        }, onClose: { _ in })
        defer { transport.close() }

        daemon.write([#"{"event":"output","surface":3,"data":"YQ==","flow":\#(flow)}"#,
                      #"{"event":"output","surface":3,"data":"Yg=="}"#])
        await log.waitForRoutes(2)
        #expect(await TerminalAttachment.next(from: queue, marking: probe) == .inputEcho(flow: flow))
        #expect(await TerminalAttachment.next(from: queue, marking: probe) == .output(Data("ab".utf8), colors: nil))

        #expect(log.steps(flow) == ["key.echo.line_out<", "key.echo.app_transport_read>", "app.output.decoded",
                                    "key.echo.app_transport_read<", "key.echo.main_actor>"])
        #expect(log.steps(0).isEmpty, "an event that names no press marked a step")
    }

    @Test func withKeyFlowsOffTheReaderMarksNothing() async throws {
        let log = StepLog()
        let probe = TypingLatencyProbe(path: nil, trace: log.runtime(), hopRecorder: { hop, flow in log.append(hop, flow) })
        let daemon = try FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil, probe: probe)
        try daemon.accept()
        let queue = TerminalEventQueue(recorder: nil)
        let decoder = transport.decoder
        transport.start(onEvent: { name, line, _ in
            if let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: Self.surface, decoder: decoder) {
                TerminalAttachment.enqueue(decoded.event, echoing: decoded.flow, on: queue, probe: probe)
            }
            log.routed()
        }, onClose: { _ in })
        defer { transport.close() }

        daemon.write([#"{"event":"output","surface":3,"data":"YQ==","flow":42}"#])
        await log.waitForRoutes(1)
        #expect(await TerminalAttachment.next(from: queue, marking: probe) == .inputEcho(flow: 42))
        #expect(log.steps(42).isEmpty)
    }
}
