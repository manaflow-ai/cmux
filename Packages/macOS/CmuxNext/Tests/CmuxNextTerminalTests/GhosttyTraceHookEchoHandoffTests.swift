import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTerminal
@testable import CmuxNextTrace
@testable import CmuxNextWakeups
import Testing

/// The renderer's, Metal completion's and main's handoffs of a key's echo (p09-observability-102), from the
/// Ghostty trace hook: the renderer takes the echo at the begin of the frame that draws it (`key.echo.renderer`
/// taken), hands the frame's GPU work on at its end (`key.echo.gpu_done` queued) and the frame to its layer at the
/// handoff (`key.echo.contents` queued); the GPU completion takes the first, and the main run-loop turn's end
/// that commits the frame the second. A frame that draws no echo marks none of them.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct GhosttyTraceHookEchoHandoffTests {
    /// The `key.echo.*` steps of `flow` in `log`, in order: `>` a flow out (queued), `<` a flow in (taken).
    private func handoffs(_ log: GhosttyTraceHookTests.RecordLog, _ flow: UInt64) -> [String] {
        log.records.compactMap { record -> String? in
            guard record.arg1 == flow, let name = SignpostName(rawValue: record.name),
                  String(describing: name).hasPrefix("key.echo.") else { return nil }
            switch record.phase {
            case .flowOut: return "\(name)>"
            case .flowIn: return "\(name)<"
            default: return nil
            }
        }
    }

    /// One key press on `key` whose echo was parsed; returns its flow.
    private func parsedPress(_ probe: TypingLatencyProbe, on key: TypingLatencyProbe.SurfaceKey) throws -> UInt64 {
        probe.keyDown(eventTimestamp: 0)
        probe.keyReachedTerminal(key, display: 7)
        probe.terminalTookKey()
        probe.mark(.dispatchEnd)
        probe.inputWritten(on: key)
        let flow = try #require(probe.openFlow)
        probe.mark(.socketSubmit, flow: flow)
        probe.outputDecoded(flow: flow)
        probe.mark(.outputReceived, flow: flow)
        probe.mark(.outputParsed, flow: flow)
        return flow
    }

    @Test func theEchosFrameCarriesItsFlowToTheGPUCompletionAndMain() throws {
        let log = GhosttyTraceHookTests.RecordLog()
        let trace = log.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()

        rig.call(.frameBegin, seq: 1)  // drawn before the key: no echo
        rig.call(.frameEnd, seq: 1)
        let flow = try parsedPress(probe, on: rig.key)
        rig.call(.frameBegin, seq: 2)
        rig.call(.frameEnd, seq: 2)
        rig.call(.contentsHandoff, seq: 2)
        rig.call(.gpuDone, seq: 1)
        rig.call(.gpuDone, seq: 2)
        probe.turnDidEnd()

        #expect(handoffs(log, flow) == ["key.echo.renderer<", "key.echo.gpu_done>", "key.echo.contents>",
                                        "key.echo.gpu_done<", "key.echo.contents<"])
        #expect(handoffs(log, 0).isEmpty, "a frame with no echo marked a handoff")
    }

    /// Two echoes parsed before one frame (fast typing): that frame draws both, so each press gets the renderer's,
    /// the GPU completion's and main's handoffs; a frame that begins before the first one's handoff takes neither
    /// again.
    @Test func everyEchoAFrameDrawsGetsItsHandoffs() throws {
        let log = GhosttyTraceHookTests.RecordLog()
        let trace = log.runtime()
        let probe = TypingLatencyProbe(path: nil, trace: trace)
        probe.startFlows()
        defer { probe.stopFlows() }
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: probe)
        rig.hook.refreshDemand()

        let first = try parsedPress(probe, on: rig.key)
        let second = try parsedPress(probe, on: rig.key)
        #expect(first != second)
        rig.call(.frameBegin, seq: 1)
        rig.call(.frameEnd, seq: 1)
        rig.call(.frameBegin, seq: 2)  // draws no new echo
        rig.call(.frameEnd, seq: 2)
        rig.call(.contentsHandoff, seq: 1)
        rig.call(.gpuDone, seq: 1)
        rig.call(.gpuDone, seq: 2)
        probe.turnDidEnd()

        for flow in [first, second] {
            #expect(handoffs(log, flow) == ["key.echo.renderer<", "key.echo.gpu_done>", "key.echo.contents>",
                                            "key.echo.gpu_done<", "key.echo.contents<"], "flow \(flow)")
        }
        #expect(handoffs(log, 0).isEmpty)
    }

    @Test func withKeyFlowsOffAFrameMarksNoHandoff() throws {
        let log = GhosttyTraceHookTests.RecordLog()
        let trace = log.runtime()
        let rig = GhosttyTraceHookTests.Rig(trace: trace, probe: TypingLatencyProbe(path: nil, trace: trace))
        rig.hook.refreshDemand()
        rig.call(.frameBegin, seq: 1)
        rig.call(.frameEnd, seq: 1)
        rig.call(.contentsHandoff, seq: 1)
        rig.call(.gpuDone, seq: 1)
        let names = log.records.compactMap { SignpostName(rawValue: $0.name).map(String.init(describing:)) }
        #expect(!names.isEmpty, "the frame wrote its render slice")
        #expect(!names.contains { $0.hasPrefix("key.echo.") })
    }
}
