import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// The output lane's thread handoffs of a key's echo (p09-observability-102): the session hands the echo's
/// marker to the lane (`key.echo.main_actor` taken), the chunk after it is queued on the lane with the press's
/// flow (`key.echo.output_lane` queued), the lane takes that chunk (taken) and its parse wakes the renderer
/// (`key.echo.renderer` queued). A chunk with no echo carries flow 0 and marks nothing, and with key flows off
/// nothing is marked at all. The lane's parse is the test's recorder, so no Ghostty surface is made.
@Suite(.timeLimit(.minutes(1))) struct TerminalOutputLaneEchoHandoffTests {
    static var surface: ghostty_surface_t { unsafeBitCast(UInt(0x1000), to: ghostty_surface_t.self) }

    /// Every record a test runtime wrote.
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        /// A runtime with every category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }

        /// The `key.echo.*` steps of `flow`, in order: `>` a flow out (queued), `<` a flow in (taken).
        func handoffs(_ flow: UInt64) -> [String] {
            state.withLock { $0 }.compactMap { record -> String? in
                guard record.arg1 == flow, let name = SignpostName(rawValue: record.name),
                      String(describing: name).hasPrefix("key.echo.") else { return nil }
                switch record.phase {
                case .flowOut: return "\(name)>"
                case .flowIn: return "\(name)<"
                default: return nil
                }
            }
        }
    }

    /// One key press on `key`, dispatched, written, sent and decoded; returns its flow.
    private func decodedPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        return flow
    }

    @Test func theEchosChunkCarriesItsFlowThroughTheLane() async throws {
        let log = RecordLog()
        let probe = TypingLatencyProbe(path: nil, trace: log.runtime())
        probe.startFlows()
        defer { probe.stopFlows() }
        let key = probe.makeSurfaceKey()
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.echo-handoffs", keyFlows: key, probe: probe) { _, _ in }
        defer { lane.close() }
        let flow = try decodedPress(probe, on: key)

        #expect(await lane.takeOffMain(.output(Data("before".utf8))))
        #expect(await lane.takeOffMain(.inputEcho(flow: flow)))
        #expect(await lane.takeOffMain(.output(Data("echo".utf8))))
        #expect(await lane.takeOffMain(.output(Data("after".utf8))))
        await lane.drained()

        #expect(log.handoffs(flow) == ["key.echo.main_actor<", "key.echo.output_lane>", "key.echo.output_lane<",
                                       "key.echo.renderer>"])
        #expect(log.handoffs(0).isEmpty, "a chunk with no echo marked a handoff")
    }

    @Test func withKeyFlowsOffTheLaneMarksNothing() async throws {
        let log = RecordLog()
        let probe = TypingLatencyProbe(path: nil, trace: log.runtime())
        let lane = TerminalOutputLane(surface: Self.surface, label: "test.echo-handoffs-off", probe: probe) { _, _ in }
        defer { lane.close() }

        #expect(await lane.takeOffMain(.inputEcho(flow: 42)))
        #expect(await lane.takeOffMain(.output(Data("echo".utf8))))
        await lane.drained()
        #expect(log.handoffs(42).isEmpty)
    }
}
