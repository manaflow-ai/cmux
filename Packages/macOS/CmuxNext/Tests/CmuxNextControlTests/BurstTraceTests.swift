#if DEBUG
@testable import CmuxNextControl
import CmuxNextSettings
import Testing

/// `debug.burst` (``BurstTrace``): marks only while armed, the first output after each grid once, and a
/// separate kind for each designed no-op Cmd-W, so the burst bench never counts one as lost.
@Suite struct BurstTraceTests {
    private func kinds(_ reply: JSONValue) -> [String] {
        (reply["events"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
    }

    @Test("A mark before start or after stop records nothing")
    func disarmedRecordsNothing() {
        let trace = BurstTrace()
        trace.mark(.refusal)
        trace.gridSent(surface: 1, cols: 80, rows: 24)
        trace.output(surface: 1)
        #expect(!trace.isArmed)
        _ = trace.control(["action": .string("start")])
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply).isEmpty)
        trace.mark(.closeSwallowed)
        _ = trace.control(["action": .string("start")])
        #expect(kinds(trace.control(["action": .string("stop")])).isEmpty)
    }

    @Test("Only the first output after a grid is marked, once per grid and surface")
    func firstOutputAfterEachGrid() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.output(surface: 7)  // no grid yet: not a first output
        trace.gridSent(surface: 7, cols: 100, rows: 30)
        trace.output(surface: 8)  // another terminal's output
        trace.output(surface: 7)
        trace.output(surface: 7)
        trace.gridSent(surface: 7, cols: 90, rows: 30)
        trace.output(surface: 7)
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["pty_grid", "first_output", "pty_grid", "first_output"])
        #expect(reply["counts"]?["first_output"]?.intValue == 2)
        #expect(reply["dropped"]?.intValue == 0)
    }

    @Test("Swallowed and cancelling Cmd-W presses and refusals each have their own kind")
    func designedNoOpsAreTyped() {
        let trace = BurstTrace()
        _ = trace.control(["action": .string("start")])
        trace.mark(.closeSwallowed)
        trace.mark(.creationCancelled)
        trace.mark(.refusal)
        let reply = trace.control(["action": .string("stop")])
        #expect(kinds(reply) == ["close_swallowed", "creation_cancelled", "refusal"])
    }
}
#endif
