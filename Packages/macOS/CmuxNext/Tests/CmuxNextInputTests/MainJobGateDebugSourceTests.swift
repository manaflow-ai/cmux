import CmuxNextControl
@testable import CmuxNextInputDiagnostics
import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Testing

/// `debug.input` section `gate` from the MainJobGate (DC10): the gate's counters by
/// origin and by exempt rule reach the section's JSON keys, `reset` starts them over, and no gate
/// (the feature off) reads as zero.
@MainActor @Suite
struct MainJobGateDebugSourceTests {
    /// Jobs as the runtime hands them out: at least 16-byte aligned.
    static func job(_ n: UInt) -> MainJobGate.Entry {
        MainJobGate.Entry(job: n << 4, original: 0, priority: 21)
    }

    @Test func theGatesCountersEncodeIntoTheGateSection() async throws {
        let state = InputPendingState()
        let gate = MainJobGate(state: state, forward: { _ in }, wakeMain: {})
        state.publish(.key)
        gate.enqueue(Self.job(1))
        gate.enqueue(Self.job(2), bits: state.bits, onMain: false)
        let outer = state.beginDispatch()
        gate.enqueue(Self.job(3))
        state.endDispatch(restoring: outer)
        let debugInput = DebugInput(sources: [MainJobGateDebugSource { gate }])

        let reply = try await debugInput.reply(to: .read([.gate]))
        let data = try JSONSerialization.data(withJSONObject: try #require(reply["gate"]).foundationObject)
        let section = try JSONDecoder().decode(DebugInputGate.self, from: data)
        #expect(section.heldByOrigin == .init(main: 1, offMain: 1))
        #expect(section.exemptByRule["in_dispatch"] == 1)
        #expect(section.jobsDeferredOverOneFrame == 0)
        #expect(reply["gate"]?["held_by_origin"]?["offMain"] == .number(1))
        #expect(reply["gate"]?["exempt_by_rule"]?["in_dispatch"] == .number(1))
        #expect(reply["gate"]?["max_input_wait_behind_jobs_ms"] == nil, "not the gate's to measure")

        _ = try await debugInput.reply(to: .reset)
        #expect(gate.counters.heldByOrigin.values.allSatisfy { $0 == 0 })
        #expect(gate.heldCount == 2, "a reset releases nothing")
    }

    @Test func noGateReadsAsZero() async {
        let section = await MainJobGateDebugSource { nil }.read()
        #expect(section.heldByOrigin == .init(main: 0, offMain: 0))
        #expect(section.exemptByRule.isEmpty)
        #expect(section.jobsDeferredOverOneFrame == 0)
    }
}
