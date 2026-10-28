import CmuxNextCompat
@testable import CmuxNextAgentPane
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Testing

/// Each agent pane mark is one `webui.agent_pane_step` instant in the trace ring, every time it happens, and none
/// goes out under the launch category (p09-observability task 035): a new tab's paint and context recur after
/// launch.
@MainActor
struct AgentPaneLaunchTimingsSignpostTests {
    /// The records a test runtime writes, in order.
    nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var records: [TraceRuntime.StubRecord] { state.withLock { $0 } }

        /// A runtime with every category on, recording into this log.
        func runtime() -> TraceRuntime {
            let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
            runtime.setCategoryMask(SignpostCategory.allCases.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
            return runtime
        }
    }

    private func timings(_ log: RecordLog) -> AgentPaneLaunchTimings {
        AgentPaneLaunchTimings(signposter: Signposter(category: .webui, mirror: SignpostMetricKitMirror(), trace: log.runtime()))
    }

    @Test("A mark is one webui.agent_pane_step instant whose arg0 is the step's code")
    func aMarkIsOneStepInstant() {
        let log = RecordLog()
        timings(log).mark("agent_pane.handshake_end")
        #expect(log.records.map(\.name) == [SignpostName.webuiAgentPaneStep.rawValue])
        #expect(log.records.map(\.phase) == [.instant])
        #expect(log.records.first?.arg0 == 4, "agent_pane.handshake_end is the 4th step of the fixed order")
        #expect(log.records.first?.categoryBit == SignpostCategory.webui.traceBit)
    }

    @Test("New-tab marks repeat after launch and write each time, never under the launch category")
    func newTabMarksAreNotLaunchSteps() {
        let log = RecordLog()
        let timings = timings(log)
        var received: [String] = []
        timings.install { received.append($0) }
        let names = ["agent_pane.painted", "agent_pane.newtab_painted", "agent_pane.newtab_context",
                     "agent_pane.newtab_painted", "agent_pane.newtab_context"]
        for name in names { timings.mark(name) }
        #expect(received == names)
        #expect(log.records.map(\.arg0) == [2, 5, 6, 5, 6])
        #expect(!log.records.contains { $0.categoryBit == SignpostCategory.launch.traceBit })
    }

    @Test("Every step has its own nonzero code; a name outside the list has code 0")
    func codesAreDistinct() {
        let codes = AgentPaneLaunchTimings.Step.allCases.map { AgentPaneLaunchTimings.Step.traceCode(of: $0.rawValue) }
        #expect(codes == Array(1...UInt64(codes.count)))
        #expect(AgentPaneLaunchTimings.Step.traceCode(of: "agent_pane.not_a_step") == 0)
    }
}
