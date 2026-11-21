import Foundation
import Testing
@testable import CmuxNextDaemon

/// The start answer's `timings_ms` (cmux-tui-core agent_session_start.rs `StartTimings`) reads as one log line beside the
/// app's own `cloud start step` lines, in the daemon's phase order, so a Cloud start's `start` step splits into the
/// harness's `session/new` and the rest.
struct AgentSessionStartTimingsTests {
    @Test func theMachinePhasesReadAsOneLineInTheDaemonsOrder() throws {
        let data = Data(#"{"total": 1815, "session_new": 1800, "keyed_gate": 1, "acpmux_connect": 2, "checks": 3, "settle": 4, "bind": 5, "acpmux_started": true}"#.utf8)
        let timings = try JSONSerialization.jsonObject(with: data)
        #expect(AgentSessionAttachClient.machineTimings(timings) ==
            "keyed_gate 1 ms, acpmux_connect 2 ms, checks 3 ms, session_new 1800 ms, settle 4 ms, bind 5 ms, total 1815 ms, acpmux_started yes")
    }

    @Test func anOlderDaemonsAnswerLogsNothing() {
        #expect(AgentSessionAttachClient.machineTimings(nil) == nil)
        #expect(AgentSessionAttachClient.machineTimings(["acpmux_started": false]) == nil)
        #expect(AgentSessionAttachClient.machineTimings("1800") == nil)
    }

    /// The same phases as numbers for start-session's `stages_ms` (`machine`): whole ms, `acpmux_started` 0 or 1.
    @Test func theMachinePhasesReadAsNumbersForTheStagesAnswer() throws {
        let data = Data(#"{"total": 1815, "session_new": 1800, "keyed_gate": 1, "acpmux_connect": 2, "checks": 3, "settle": 4, "bind": 5, "acpmux_started": true}"#.utf8)
        let timings = try JSONSerialization.jsonObject(with: data)
        #expect(AgentSessionAttachClient.machinePhases(timings) ==
            ["keyed_gate": 1, "acpmux_connect": 2, "checks": 3, "session_new": 1800, "settle": 4, "bind": 5, "total": 1815, "acpmux_started": 1])
        #expect(AgentSessionAttachClient.machinePhases(nil) == nil)
        #expect(AgentSessionAttachClient.machinePhases("1800") == nil)
    }
}
